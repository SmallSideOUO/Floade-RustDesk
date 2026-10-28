//! An independently encrypted/congestion-controlled P2P connection for desktop video.
//! Signaling stays on the authenticated control connection; input never enters this worker.
use std::sync::Arc;

use base::message_proto::{message, misc, video_channel_signal::Kind, Message, VideoChannelSignal};
use bytes::BytesMut;
use hbb_common::{
    anyhow::{anyhow, bail},
    protobuf::Message as _,
    tokio::{
        self,
        sync::mpsc,
        task::JoinHandle,
        time::{timeout_at, Duration, Instant},
    },
    webrtc::WebRTCStream,
    ResultType,
};

const SETUP_TIMEOUT: Duration = Duration::from_secs(15);
const SEND_TIMEOUT_MS: u64 = 5000;
const VIDEO_QUEUE: usize = 4;
const MAX_VIDEO_BYTES: usize = 16 * 1024 * 1024;

pub fn enabled() -> bool {
    crate::get_app_name() == "FloadeRemote"
        && std::env::var("FLOADE_RUSTDESK_SPLIT_VIDEO").as_deref() != Ok("0")
}

pub fn is_video(msg: &Message) -> bool {
    match msg.union.as_ref() {
        Some(message::Union::VideoFrame(_)) => true,
        Some(message::Union::Misc(m)) => matches!(m.union, Some(misc::Union::SwitchDisplay(_))),
        _ => false,
    }
}

pub fn signal(kind: Kind, value: String) -> Message {
    let mut msg = Message::new();
    msg.set_video_channel_signal(VideoChannelSignal {
        kind: kind.into(),
        value,
        ..Default::default()
    });
    msg
}

pub enum Event {
    Signal(Message),
    Active,
    Frame(BytesMut),
    Writable,
    Failed { active: bool, reason: String },
}

pub struct VideoChannel {
    commands: mpsc::Sender<VideoChannelSignal>,
    frames: mpsc::Sender<Arc<Message>>,
    events: mpsc::Receiver<Event>,
    worker: JoinHandle<()>,
    active: bool,
    barrier: bool,
}

impl Drop for VideoChannel {
    fn drop(&mut self) {
        self.worker.abort();
    }
}

// A WebRTCStream clone is not an owner. Close even if setup, a send, or the session is cancelled.
struct CloseOnDrop(WebRTCStream);
impl Drop for CloseOnDrop {
    fn drop(&mut self) {
        self.0.close_detached();
    }
}

struct AbortOnDrop(JoinHandle<()>);
impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

impl VideoChannel {
    pub fn offer() -> Self {
        Self::start(None)
    }

    pub fn answer(offer: VideoChannelSignal) -> ResultType<Self> {
        validate_signal(&offer)?;
        if offer.kind.enum_value() != Ok(Kind::Offer) {
            bail!("Expected video offer");
        }
        Ok(Self::start(Some(offer.value)))
    }

    fn start(offer: Option<String>) -> Self {
        let (command_tx, command_rx) = mpsc::channel(64);
        let (frame_tx, frame_rx) = mpsc::channel(VIDEO_QUEUE);
        let (event_tx, event_rx) = mpsc::channel(8);
        let worker = tokio::spawn(async move {
            let mut active = false;
            if let Err(error) = run(offer, command_rx, frame_rx, &event_tx, &mut active).await {
                let _ = event_tx
                    .send(Event::Failed {
                        active,
                        reason: error.to_string(),
                    })
                    .await;
            }
        });
        Self {
            commands: command_tx,
            frames: frame_tx,
            events: event_rx,
            worker,
            active: false,
            barrier: false,
        }
    }

    pub fn handle_signal(&self, msg: VideoChannelSignal) -> ResultType<()> {
        validate_signal(&msg)?;
        if msg.kind.enum_value() == Ok(Kind::Cancel) {
            bail!("Peer cancelled video channel");
        }
        self.commands
            .try_send(msg)
            .map_err(|_| anyhow!("Video signaling unavailable"))
    }

    pub fn active(&self) -> bool {
        self.active
    }
    pub fn pending_events(&self) -> usize {
        self.events.len()
    }

    pub fn can_take_video(&self) -> bool {
        !self.barrier && (!self.active || self.frames.capacity() > 0)
    }

    // Single producer. Check capacity in the session's select guard; no await on the control loop.
    pub fn send_video(&self, msg: Arc<Message>) -> ResultType<()> {
        if !self.active || !is_video(&msg) {
            bail!("Invalid video channel send");
        }
        self.frames
            .try_send(msg)
            .map_err(|_| anyhow!("Video channel queue unavailable"))
    }

    async fn next(&mut self) -> Event {
        let event = self.events.recv().await.unwrap_or_else(|| Event::Failed {
            active: self.active,
            reason: "Video worker stopped".to_owned(),
        });
        match &event {
            Event::Active => {
                self.active = true;
                self.barrier = false;
            }
            Event::Signal(msg)
                if msg.video_channel_signal().kind.enum_value() == Ok(Kind::Ready) =>
            {
                // Stop legacy video before putting the Ready barrier on the control stream.
                // The receiver processes every older legacy frame before replying Ready.
                self.barrier = true;
            }
            _ => {}
        }
        event
    }
}

pub async fn next(channel: &mut Option<VideoChannel>) -> Event {
    match channel.as_mut() {
        Some(channel) => channel.next().await,
        None => std::future::pending().await,
    }
}

pub fn can_take_video(channel: &Option<VideoChannel>) -> bool {
    channel.as_ref().map_or(true, VideoChannel::can_take_video)
}

fn validate_signal(msg: &VideoChannelSignal) -> ResultType<Kind> {
    let kind = msg
        .kind
        .enum_value()
        .map_err(|_| anyhow!("Unknown video signal"))?;
    let valid = match kind {
        Kind::Offer | Kind::Answer => {
            !msg.value.is_empty()
                && msg.value.len() <= 16 * 1024
                && hbb_common::webrtc::is_webrtc_endpoint(&msg.value)
        }
        Kind::Candidate => msg.value.len() <= 4096,
        Kind::Ready | Kind::Cancel => msg.value.is_empty(),
    };
    if !valid {
        bail!("Invalid video signal");
    }
    Ok(kind)
}

async fn emit(tx: &mpsc::Sender<Event>, event: Event) -> ResultType<()> {
    tx.send(event)
        .await
        .map_err(|_| anyhow!("Video session ended"))
}

async fn run(
    offer: Option<String>,
    mut commands: mpsc::Receiver<VideoChannelSignal>,
    mut frames: mpsc::Receiver<Arc<Message>>,
    events: &mpsc::Sender<Event>,
    active: &mut bool,
) -> ResultType<()> {
    let receiver = offer.is_none();
    let deadline = Instant::now() + SETUP_TIMEOUT;
    let mut stream = timeout_at(
        deadline,
        WebRTCStream::new(offer.as_deref().unwrap_or(""), false, SEND_TIMEOUT_MS),
    )
    .await??;
    let _close = CloseOnDrop(stream.clone());
    stream.set_max_packet_length(MAX_VIDEO_BYTES);
    let kind = if receiver { Kind::Offer } else { Kind::Answer };
    emit(
        events,
        Event::Signal(signal(kind, stream.local_endpoint().to_owned())),
    )
    .await?;
    let mut ice = stream
        .take_local_ice_rx()
        .ok_or_else(|| anyhow!("Missing video ICE receiver"))?;
    let mut waiting = stream.clone();
    let mut connected = Box::pin(waiting.wait_connected(SETUP_TIMEOUT.as_millis() as u64));
    let mut connection_done = false;
    let mut ready_sent = false;
    let mut remote_ready = false;
    let mut answered = !receiver;
    timeout_at(deadline, async {
        loop {
            // Only the host initiates the barrier. The client replies after consuming it
            // from the ordered control connection, so old/new video cannot overtake each other.
            if connection_done && (!receiver || remote_ready) && !ready_sent {
                emit(events, Event::Signal(signal(Kind::Ready, String::new()))).await?;
                ready_sent = true;
            }
            if ready_sent && remote_ready {
                break;
            }
            tokio::select! {
                result = &mut connected, if !connection_done => {
                    result?;
                    connection_done = true;
                }
                command = commands.recv() => {
                    let command = command.ok_or_else(|| anyhow!("Video signaling ended"))?;
                    match validate_signal(&command)? {
                        Kind::Answer if receiver && !answered => {
                            stream.set_remote_endpoint(&command.value).await?;
                            answered = true;
                        }
                        Kind::Candidate => stream.add_remote_ice_candidate(&command.value).await?,
                        Kind::Ready if !remote_ready => {
                            remote_ready = true;
                        }
                        _ => bail!("Unexpected video setup signal"),
                    }
                }
                Some(candidate) = ice.recv() => {
                    emit(events, Event::Signal(signal(Kind::Candidate, candidate))).await?;
                }
            }
        }
        Ok::<(), hbb_common::anyhow::Error>(())
    })
    .await??;
    if stream.is_relayed().await != Some(false) {
        bail!("Video channel is not direct P2P");
    }
    // The remote description (and its DTLS fingerprint) arrived through the authenticated
    // primary stream. webrtc-rs verifies the certificate against that fingerprint.
    stream.remote_dtls_fingerprint().await?;
    *active = true;
    emit(events, Event::Active).await?;

    let (read_error_tx, mut read_error_rx) = mpsc::channel(1);
    let mut reader = stream.clone();
    let frame_events = events.clone();
    let _reader = AbortOnDrop(tokio::spawn(async move {
        let result: ResultType<()> = async {
            loop {
                let bytes = reader
                    .next()
                    .await
                    .ok_or_else(|| anyhow!("Video connection closed"))??;
                let msg = Message::parse_from_bytes(&bytes)?;
                if !receiver || !is_video(&msg) {
                    bail!("Non-video payload on video connection");
                }
                emit(&frame_events, Event::Frame(bytes)).await?;
            }
        }
        .await;
        let _ = read_error_tx.send(result).await;
    }));
    loop {
        tokio::select! {
            Some(msg) = frames.recv(), if !receiver => {
                if msg.compute_size() > MAX_VIDEO_BYTES as u64 { bail!("Video frame too large"); }
                stream.send(msg.as_ref()).await?;
                emit(events, Event::Writable).await?;
            }
            result = read_error_rx.recv() => {
                return result.unwrap_or_else(|| Err(anyhow!("Video reader stopped")));
            }
            command = commands.recv() => {
                let command = command.ok_or_else(|| anyhow!("Video signaling ended"))?;
                if validate_signal(&command)? != Kind::Candidate { bail!("Unexpected active video signal"); }
                stream.add_remote_ice_candidate(&command.value).await?;
            }
            Some(candidate) = ice.recv() => {
                emit(events, Event::Signal(signal(Kind::Candidate, candidate))).await?;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base::message_proto::{
        EncodedVideoFrame, EncodedVideoFrames, KeyEvent, Misc, SwitchDisplay, VideoFrame,
    };
    use hbb_common::tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::{TcpListener, TcpStream},
        time::timeout,
    };

    async fn pair() -> (VideoChannel, VideoChannel) {
        timeout(Duration::from_secs(20), async {
            let mut client = VideoChannel::offer();
            let Event::Signal(offer) = client.next().await else { panic!("Expected video offer"); };
            let mut host = VideoChannel::answer(offer.video_channel_signal().clone()).unwrap();
            while !client.active() || !host.active() {
                tokio::select! {
                    event = client.next() => match event {
                        Event::Signal(msg) => host.handle_signal(msg.video_channel_signal().clone()).unwrap(),
                        Event::Active | Event::Writable => {},
                        Event::Failed { reason, .. } => panic!("Client: {reason}"),
                        _ => panic!("Unexpected client event"),
                    },
                    event = host.next() => match event {
                        Event::Signal(msg) => client.handle_signal(msg.video_channel_signal().clone()).unwrap(),
                        Event::Active | Event::Writable => {},
                        Event::Failed { reason, .. } => panic!("Host: {reason}"),
                        _ => panic!("Unexpected host event"),
                    },
                }
            }
            (client, host)
        }).await.expect("Video handshake timed out")
    }

    fn video(pts: i64, bytes: usize) -> Arc<Message> {
        let mut frame = VideoFrame::new();
        frame.set_h264s(EncodedVideoFrames {
            frames: vec![EncodedVideoFrame {
                data: vec![42; bytes].into(),
                pts,
                key: pts == 0,
                ..Default::default()
            }],
            ..Default::default()
        });
        let mut msg = Message::new();
        msg.set_video_frame(frame);
        Arc::new(msg)
    }

    #[tokio::test]
    async fn independent_video_preserves_display_and_predictive_frame_order() {
        let (mut client, mut host) = pair().await;
        let mut display = Misc::new();
        display.set_switch_display(SwitchDisplay::new());
        let mut change = Message::new();
        change.set_misc(display);
        let messages = vec![Arc::new(change), video(0, 180_000), video(1, 100_000)];
        for msg in &messages {
            host.send_video(msg.clone()).unwrap();
        }
        timeout(Duration::from_secs(5), async {
            for expected in messages {
                loop {
                    tokio::select! {
                        event = client.next() => match event {
                            Event::Frame(bytes) => {
                                assert_eq!(bytes.as_ref(), expected.write_to_bytes().unwrap());
                                break;
                            }
                            Event::Signal(msg) => host.handle_signal(msg.video_channel_signal().clone()).unwrap(),
                            Event::Failed { reason, .. } => panic!("{reason}"),
                            _ => {},
                        },
                        event = host.next() => match event {
                            Event::Signal(msg) => client.handle_signal(msg.video_channel_signal().clone()).unwrap(),
                            Event::Failed { reason, .. } => panic!("{reason}"),
                            _ => {},
                        },
                    }
                }
            }
        }).await.expect("Video delivery timed out");
        let mut input = Message::new();
        input.set_key_event(KeyEvent::new());
        assert!(host.send_video(Arc::new(input)).is_err());
    }

    #[tokio::test]
    async fn full_video_queue_leaves_control_input_responsive() {
        let (_client, host) = pair().await;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut sender = TcpStream::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        let (mut receiver, _) = listener.accept().await.unwrap();
        let mut input = Message::new();
        input.set_key_event(KeyEvent {
            down: true,
            ..Default::default()
        });
        let encoded = input.write_to_bytes().unwrap();
        sender.write_all(&encoded).await.unwrap();
        // No yield: fill the producer, leaving more video ready in the server queue.
        let frame = video(0, 1024 * 1024);
        for _ in 0..VIDEO_QUEUE {
            host.send_video(frame.clone()).unwrap();
        }
        assert!(!host.can_take_video());
        assert!(host.send_video(frame.clone()).is_err());
        let channel = Some(host);
        let (video_tx, mut video_rx) = mpsc::unbounded_channel();
        video_tx.send(frame).unwrap();
        timeout(Duration::from_secs(1), async {
            let mut received = vec![0; encoded.len()];
            tokio::select! {
                biased;
                _ = video_rx.recv(), if can_take_video(&channel) => panic!("Full video queue blocked control dispatch"),
                result = receiver.read_exact(&mut received) => { result.unwrap(); }
            }
            assert_eq!(
                Message::parse_from_bytes(&received)
                    .unwrap()
                    .key_event()
                    .down,
                true
            );
        })
        .await
        .expect("Input blocked behind video");
    }

    #[tokio::test]
    async fn invalid_offers_are_refused_and_session_disposal_closes_video() {
        assert!(VideoChannel::answer(VideoChannelSignal {
            value: "untrusted endpoint".into(),
            ..Default::default()
        })
        .is_err());
        let (mut client, host) = pair().await;
        drop(host);
        timeout(Duration::from_secs(5), async {
            loop {
                if let Event::Failed { active, .. } = client.next().await {
                    assert!(active);
                    break;
                }
            }
        })
        .await
        .expect("Dropping the host did not close the independent video connection");
    }
}
