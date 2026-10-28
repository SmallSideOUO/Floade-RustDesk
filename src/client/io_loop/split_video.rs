use super::*;
use crate::split_video::{self, Event};
use base::message_proto::video_channel_signal::Kind;

impl<T: InvokeUiSession> Remote<T> {
    pub(super) async fn handle_split_video_signal(
        &mut self,
        signal: VideoChannelSignal,
        peer: &mut Stream,
    ) -> bool {
        let Some(channel) = self.split_video.as_ref() else {
            return true;
        };
        if let Err(error) = channel.handle_signal(signal) {
            return self
                .split_video_failed(channel.active(), error.to_string(), peer)
                .await;
        }
        true
    }

    pub(super) async fn handle_split_video_event(
        &mut self,
        event: Event,
        peer: &mut Stream,
    ) -> bool {
        match event {
            Event::Signal(msg) => {
                if let Err(error) = peer.send(&msg).await {
                    self.handler
                        .on_establish_connection_error(error.to_string());
                    return false;
                }
            }
            Event::Active => {
                log::info!("Floade video uses independent direct P2P; input stays on control")
            }
            Event::Frame(bytes) => {
                self.data_count.fetch_add(bytes.len(), Ordering::Relaxed);
                return self.handle_msg_from_peer(&bytes, peer).await;
            }
            Event::Failed { active, reason } => {
                return self.split_video_failed(active, reason, peer).await;
            }
            Event::Writable => {}
        }
        true
    }

    async fn split_video_failed(
        &mut self,
        active: bool,
        reason: String,
        peer: &mut Stream,
    ) -> bool {
        self.split_video = None;
        if active {
            self.handler
                .on_establish_connection_error(format!("Video channel: {reason}"));
            return false;
        }
        log::info!("Independent video unavailable; retaining legacy video: {reason}");
        peer.send(&split_video::signal(Kind::Cancel, String::new()))
            .await
            .is_ok()
    }
}
