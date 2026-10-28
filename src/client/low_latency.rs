use std::time::Duration;

pub fn enabled() -> bool {
    std::env::var("FLOADE_RUSTDESK_LOW_LATENCY").as_deref() == Ok("1")
}

pub fn diagnostics_enabled() -> bool {
    enabled() || std::env::var("FLOADE_RUSTDESK_TEST_PROFILE").as_deref() == Ok("1")
}

#[derive(Default)]
pub struct BitrateFeedback {
    pub last_delay_ms: u32,
    pub target_bitrate: Option<u32>,
    pub quality: Option<i32>,
    ceiling: Option<i32>,
    bad_samples: u8,
    good_samples: u8,
    cooldown: u8,
}

impl BitrateFeedback {
    // This is a compatibility brake for old hosts; newer hosts own their QoS loop.
    // Return wire quality only: never persist congestion into the user's settings.
    pub fn observe(&mut self, delay_ms: u32, ceiling: Option<i32>) -> Option<i32> {
        self.last_delay_ms = delay_ms;
        if self.ceiling != ceiling {
            self.quality = ceiling;
            self.ceiling = ceiling;
            self.bad_samples = 0;
            self.good_samples = 0;
            self.cooldown = 0;
        }
        let ceiling = ceiling?;
        let current = self.quality?;
        if delay_ms == 0 {
            return None;
        }
        self.bad_samples = if delay_ms >= 500 {
            self.bad_samples.saturating_add(1)
        } else {
            0
        };
        self.good_samples = if delay_ms <= 200 {
            self.good_samples.saturating_add(1)
        } else {
            0
        };
        if self.cooldown > 0 {
            self.cooldown -= 1;
            return None;
        }
        let next = if self.bad_samples >= 2 {
            (current / 2).max(10).min(ceiling)
        } else if self.good_samples >= 5 {
            (current + 5).min(ceiling)
        } else {
            current
        };
        if next == current {
            return None;
        }
        self.quality = Some(next);
        self.bad_samples = 0;
        self.good_samples = 0;
        self.cooldown = 2;
        Some(next)
    }
}

#[derive(Default)]
pub struct PresentationBudget {
    last_presented: Option<Duration>,
}

impl PresentationBudget {
    pub fn should_present(&mut self, queued: usize, now: Duration, fps: usize) -> bool {
        // Decode every predictive frame, but spend UI work on the newest image.
        let interval = Duration::from_nanos(1_000_000_000 / fps.clamp(1, 120) as u64);
        let due = self
            .last_presented
            .map_or(true, |last| now.saturating_sub(last) >= interval);
        if queued == 0 || due {
            self.last_presented = Some(now);
            true
        } else {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sustained_one_second_delay_reduces_wire_quality_and_recovers_under_user_ceiling() {
        let mut feedback = BitrateFeedback::default();
        assert_eq!(feedback.observe(1100, Some(70)), None);
        assert_eq!(feedback.observe(1200, Some(70)), Some(35));
        assert_eq!(feedback.observe(1300, Some(70)), None);
        assert_eq!(feedback.observe(1400, Some(70)), None);
        assert_eq!(feedback.observe(1100, Some(70)), Some(17));
        for _ in 0..50 {
            feedback.observe(100, Some(70));
        }
        assert_eq!(feedback.quality, Some(67));
        for _ in 0..10 {
            feedback.observe(100, Some(70));
        }
        assert_eq!(feedback.quality, Some(70));
        assert_eq!(feedback.observe(1000, None), None);
        assert_eq!(feedback.quality, None);
    }

    #[test]
    fn a_single_spike_does_not_reduce_quality() {
        let mut feedback = BitrateFeedback::default();
        feedback.observe(100, Some(70));
        assert_eq!(feedback.observe(1200, Some(70)), None);
        assert_eq!(feedback.observe(100, Some(70)), None);
        assert_eq!(feedback.quality, Some(70));
    }

    #[test]
    fn queued_frames_skip_presentation_without_starving_the_display() {
        let mut budget = PresentationBudget::default();
        assert!(budget.should_present(20, Duration::ZERO, 60));
        assert!(!budget.should_present(19, Duration::from_millis(5), 60));
        assert!(!budget.should_present(18, Duration::from_millis(10), 60));
        assert!(budget.should_present(17, Duration::from_millis(17), 60));
        assert!(budget.should_present(16, Duration::from_millis(100), 60));
        assert!(!budget.should_present(15, Duration::from_millis(110), 60));
        assert!(budget.should_present(0, Duration::from_millis(111), 60));
    }

    #[test]
    fn high_fps_backlog_does_not_wait_for_a_sixty_hz_presentation_budget() {
        for fps in [90, 120] {
            let mut budget = PresentationBudget::default();
            let interval = Duration::from_nanos(1_000_000_000 / fps as u64);
            assert!(budget.should_present(3, Duration::ZERO, fps));
            assert!(!budget.should_present(2, Duration::from_millis(1), fps));
            assert!(budget.should_present(1, interval, fps));
            assert!(budget.should_present(1, interval * 2, fps));
            assert!(budget.should_present(0, interval * 2 + Duration::from_millis(1), fps));
        }
    }
}
