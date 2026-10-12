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
    skipped_since_present: bool,
}

impl PresentationBudget {
    pub fn should_present(&mut self, queued: usize, now: Duration) -> bool {
        // Decode every predictive frame, but spend UI work on the newest image.
        // Always allow one decode-only frame to catch up, even if painting was slow.
        let due = self.last_presented.map_or(true, |last| {
            now.saturating_sub(last) >= Duration::from_millis(16)
        });
        if queued == 0 || self.last_presented.is_none() || (due && self.skipped_since_present) {
            self.last_presented = Some(now);
            self.skipped_since_present = false;
            true
        } else {
            self.skipped_since_present = true;
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
        assert!(budget.should_present(20, Duration::ZERO));
        assert!(!budget.should_present(19, Duration::from_millis(5)));
        assert!(!budget.should_present(18, Duration::from_millis(10)));
        assert!(budget.should_present(17, Duration::from_millis(16)));
        assert!(!budget.should_present(16, Duration::from_millis(100)));
        assert!(budget.should_present(15, Duration::from_millis(110)));
        assert!(budget.should_present(0, Duration::from_millis(111)));
    }
}
