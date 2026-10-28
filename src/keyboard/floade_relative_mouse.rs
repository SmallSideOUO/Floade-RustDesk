use super::*;
use hbb_common::config::{self, LocalConfig};
use std::collections::HashSet;

const OPTION: &str = "floade-relative-mouse-shortcut";

#[derive(Default)]
struct ShortcutState {
    down: HashSet<Key>,
    blocked: HashSet<Key>,
}

lazy_static::lazy_static! {
    static ref STATE: Mutex<ShortcutState> = Mutex::new(ShortcutState::default());
}

fn key_name(key: Key) -> String {
    match key {
        Key::ControlLeft | Key::ControlRight => "Ctrl".into(),
        Key::Alt => "Alt".into(),
        Key::ShiftLeft | Key::ShiftRight => "Shift".into(),
        _ => format!("{:?}", key).replace("Key", "").replace("Num", ""),
    }
}

fn parse(value: &str) -> Option<HashSet<String>> {
    let mut keys = HashSet::new();
    let mut primary = 0;
    for token in value.split('+').map(str::trim) {
        let valid = matches!(token, "Ctrl" | "Alt" | "Shift")
            || (token.len() == 1
                && token
                    .bytes()
                    .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit()))
            || token
                .strip_prefix('F')
                .and_then(|s| s.parse::<u8>().ok())
                .map_or(false, |n| {
                    (1..=12).contains(&n) && token == format!("F{}", n)
                });
        if !valid || !keys.insert(token.to_owned()) {
            return None;
        }
        if !matches!(token, "Ctrl" | "Alt" | "Shift") {
            primary += 1;
        }
    }
    if primary > 1
        || (primary == 0 && !(keys.contains("Ctrl") && keys.contains("Alt")))
        || (primary == 1 && keys.len() == 1 && !keys.iter().any(|k| k.starts_with('F')))
    {
        return None;
    }
    Some(keys)
}

impl ShortcutState {
    fn event(&mut self, key: Key, press: bool, shortcut: &HashSet<String>) -> (bool, bool) {
        if !press {
            self.down.remove(&key);
            return (self.blocked.remove(&key), false);
        }
        let fresh = self.down.insert(key);
        if !fresh {
            return (self.blocked.contains(&key), false);
        }
        let held: HashSet<_> = self.down.iter().copied().map(key_name).collect();
        let modifiers = |keys: &HashSet<String>| {
            keys.iter()
                .filter(|k| {
                    matches!(
                        k.as_str(),
                        "Ctrl" | "Alt" | "Shift" | "MetaLeft" | "MetaRight" | "AltGr"
                    )
                })
                .cloned()
                .collect::<HashSet<_>>()
        };
        if shortcut.contains(&key_name(key))
            && shortcut.is_subset(&held)
            && modifiers(&held) == modifiers(shortcut)
        {
            self.blocked.extend(
                self.down
                    .iter()
                    .copied()
                    .filter(|k| shortcut.contains(&key_name(*k))),
            );
            return (true, true);
        }
        (false, false)
    }
}

pub(super) fn reset() {
    *STATE.lock().unwrap() = ShortcutState::default();
}

// Some(false) also bypasses the upstream exit-only Ctrl+Alt shortcut when customized.
pub(super) fn handle(key: Key, press: bool) -> Option<bool> {
    if config::APP_NAME.read().unwrap().as_str() != "FloadeRemote" {
        return None;
    }
    if !KEYBOARD_HOOKED.load(Ordering::SeqCst) {
        reset();
        return Some(false);
    }
    let session = match flutter::get_cur_session() {
        Some(session) => session,
        None => return Some(false),
    };
    let lc = session.lc.read().unwrap();
    if !session.is_default()
        || !*session.server_keyboard_enabled.read().unwrap()
        || lc.view_only.v
        || !crate::common::is_support_relative_mouse_mode_num(lc.version)
        || lc.info.platform == "Linux"
    {
        reset();
        return Some(false);
    }
    drop(lc);
    let value = LocalConfig::get_option(OPTION);
    let shortcut = parse(&value).or_else(|| parse("Ctrl+Alt"))?;
    let (blocked, toggle) = STATE.lock().unwrap().event(key, press, &shortcut);
    if blocked {
        rdev::set_modifier(key, press);
    }
    if toggle {
        release_remote_keys_for_events(&get_keyboard_mode(), take_remote_keys());
        let session_id = flutter::get_cur_session_id();
        flutter::push_session_event(&session_id, "floade_toggle_relative_mouse", vec![]);
    }
    Some(blocked)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(windows)]
    #[test]
    fn physical_game_keys_have_independent_down_and_up_events() {
        let mut held = HashSet::new();
        let mut shortcut = ShortcutState::default();
        let chord = parse("Ctrl+Alt").unwrap();
        for (key, scan, down) in [
            (Key::KeyW, 0x11, true),
            (Key::ShiftLeft, 0x2A, true),
            (Key::Space, 0x39, true),
            (Key::Space, 0x39, false),
            (Key::KeyW, 0x11, false),
            (Key::ShiftLeft, 0x2A, false),
        ] {
            assert_eq!(shortcut.event(key, down, &chord), (false, false));
            let event = Event {
                time: std::time::SystemTime::now(),
                unicode: None,
                event_type: if down {
                    EventType::KeyPress(key)
                } else {
                    EventType::KeyRelease(key)
                },
                platform_code: 0,
                position_code: scan,
                usb_hid: 0,
                extra_data: 0,
            };
            let events = event_to_key_events("windows".into(), &event, KeyboardMode::Map, Some(0));
            assert_eq!(events.len(), 1);
            assert_eq!(events[0].chr(), scan);
            assert_eq!(events[0].down, down);
            assert!(!events[0].press);
            if down {
                held.insert(scan);
            } else {
                held.remove(&scan);
            }
            if scan == 0x39 && down {
                assert_eq!(held.len(), 3);
            }
        }
        assert!(held.is_empty());
    }

    #[test]
    fn default_chord_toggles_in_either_order_without_repeat_or_orphan_releases() {
        let shortcut = parse("Ctrl+Alt").unwrap();
        for pair in [[Key::ControlLeft, Key::Alt], [Key::Alt, Key::ControlRight]] {
            let mut state = ShortcutState::default();
            assert_eq!(state.event(pair[0], true, &shortcut), (false, false));
            assert_eq!(state.event(pair[1], true, &shortcut), (true, true));
            assert_eq!(state.event(pair[1], true, &shortcut), (true, false));
            assert_eq!(state.event(pair[0], false, &shortcut), (true, false));
            assert_eq!(state.event(pair[1], false, &shortcut), (true, false));
            assert_eq!(state.event(pair[0], true, &shortcut), (false, false));
            assert_eq!(state.event(pair[1], true, &shortcut), (true, true));
        }
        let mut state = ShortcutState::default();
        state.event(Key::KeyW, true, &shortcut);
        state.event(Key::ControlLeft, true, &shortcut);
        assert_eq!(state.event(Key::Alt, true, &shortcut), (true, true));
    }

    #[test]
    fn custom_chord_does_not_toggle_at_modifier_prefix_or_extra_modifiers() {
        let shortcut = parse("Ctrl+Alt+M").unwrap();
        let mut state = ShortcutState::default();
        state.event(Key::ControlLeft, true, &shortcut);
        assert_eq!(state.event(Key::Alt, true, &shortcut), (false, false));
        assert_eq!(state.event(Key::KeyM, true, &shortcut), (true, true));
        assert!(parse("F8").is_some());
        for invalid in ["", "M", "Ctrl", "Ctrl+Ctrl+M", "Ctrl+M+N", "F13"] {
            assert!(parse(invalid).is_none());
        }
        let mut state = ShortcutState::default();
        state.event(Key::ShiftLeft, true, &shortcut);
        state.event(Key::ControlLeft, true, &shortcut);
        state.event(Key::Alt, true, &shortcut);
        assert_eq!(state.event(Key::KeyM, true, &shortcut), (false, false));
    }
}
