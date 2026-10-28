use super::*;
use crate::split_video::{self, Event, VideoChannel};
use base::message_proto::video_channel_signal::Kind;

impl Connection {
    pub(super) async fn handle_split_video_signal(&mut self, signal: VideoChannelSignal) -> bool {
        if !crate::split_video::enabled()
            || !self.stream.is_secured()
            || self.authed_conn_type() != Some(AuthConnType::Remote)
        {
            return true;
        }
        if signal.kind.enum_value() == Ok(Kind::Offer) && self.split_video.is_none() {
            match VideoChannel::answer(signal) {
                Ok(channel) => self.split_video = Some(channel),
                Err(error) => {
                    return self
                        .handle_split_video_event(Event::Failed {
                            active: false,
                            reason: error.to_string(),
                        })
                        .await
                }
            }
        } else if let Some(channel) = self.split_video.as_ref() {
            if let Err(error) = channel.handle_signal(signal) {
                return self
                    .handle_split_video_event(Event::Failed {
                        active: channel.active(),
                        reason: error.to_string(),
                    })
                    .await;
            }
        }
        true
    }

    pub(super) async fn handle_split_video_event(&mut self, event: Event) -> bool {
        match event {
            Event::Signal(msg) => {
                if let Err(error) = self.stream.send(&msg).await {
                    self.on_close(&error.to_string(), false).await;
                    return false;
                }
            }
            Event::Active => {
                log::info!("Floade video uses independent direct P2P; input stays on control")
            }
            Event::Writable => {}
            Event::Failed { active, reason } => {
                self.split_video = None;
                if active {
                    self.on_close(&format!("Video channel: {reason}"), false)
                        .await;
                    return false;
                }
                log::info!("Independent video unavailable; retaining legacy video: {reason}");
                if let Err(error) = self
                    .stream
                    .send(&split_video::signal(Kind::Cancel, String::new()))
                    .await
                {
                    self.on_close(&error.to_string(), false).await;
                    return false;
                }
            }
            Event::Frame(_) => return false,
        }
        true
    }
}
