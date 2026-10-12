use super::*;

impl<T: InvokeUiSession> Remote<T> {
    pub(super) fn low_latency_feedback(&mut self, delay: u32, bitrate: u32) {
        let Some(feedback) = self.low_latency.as_mut() else {
            return;
        };
        feedback.target_bitrate = (bitrate > 0).then_some(bitrate);
        let lc = self.handler.lc.read().unwrap();
        let ceiling = if client::low_latency::enabled()
            && lc.version > 0
            && lc.version < hbb_common::get_version_number("1.5.0")
            && lc.image_quality == "custom"
        {
            let quality = lc.custom_image_quality.first().copied().unwrap_or(50);
            let quality =
                if crate::using_public_server() && lc.direct != Some(true) && quality > 100 {
                    50
                } else {
                    quality
                };
            Some(quality.clamp(10, 2000))
        } else {
            None
        };
        drop(lc);
        if let Some(quality) = feedback.observe(delay, ceiling) {
            let mut misc = Misc::new();
            misc.set_option(OptionMessage {
                custom_image_quality: quality << 8,
                ..Default::default()
            });
            let mut msg = Message::new();
            msg.set_misc(misc);
            if let Err(error) = self.sender.send(Data::Message(msg)) {
                hbb_common::throttled_log!(
                    Duration::from_secs(5),
                    warn,
                    "Low latency quality feedback failed: {error}"
                );
            }
        }
    }

    pub(super) fn log_low_latency_status(
        &self,
        direct: bool,
        fps: &HashMap<usize, i32>,
        speed: &str,
    ) {
        let Some(feedback) = self.low_latency.as_ref() else {
            return;
        };
        let lc = self.handler.lc.read().unwrap();
        let effective_fps = *lc.custom_fps.lock().unwrap();
        let status = serde_json::json!({
            "schema": 1,
            "sample_unix_ms": get_time(),
            "session": lc.session_id,
            "peer_version": lc.peer_info.as_ref().map(|peer| peer.version.as_str()),
            "low_latency_enabled": client::low_latency::enabled(),
            "direct": direct,
            "shared_path_delay_ms": (feedback.last_delay_ms > 0).then_some(feedback.last_delay_ms),
            "presented_fps": fps,
            "decode_queue_frames": self.video_threads.iter().map(|(display, thread)|
                (display.to_string(), thread.video_queue.read().unwrap().len())
            ).collect::<HashMap<_, _>>(),
            "codec": format!("{:?}", self.video_format),
            "target_bitrate": feedback.target_bitrate,
            "receive_rate": speed,
            "effective_fps_limit": effective_fps,
            "automatic_fps_limit": lc.last_auto_fps,
            "requested_fps": lc.options.get("custom-fps"),
            "wire_quality": feedback.quality,
            "saved_quality": lc.custom_image_quality.first(),
            "legacy_bitrate_feedback_enabled": feedback.quality.is_some(),
        });
        hbb_common::throttled_log!(Duration::from_secs(5), info, "floade_perf {status}");
    }
}
