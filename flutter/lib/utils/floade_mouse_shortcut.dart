import 'package:flutter/services.dart';

const floadeMouseShortcutOption = 'floade-relative-mouse-shortcut';

class FloadeMouseShortcut {
  final Set<String> keys;
  FloadeMouseShortcut._(this.keys);

  static FloadeMouseShortcut? parse(String value) {
    final keys = value.split('+').map((s) => s.trim()).toSet();
    if (keys.length != value.split('+').length ||
        keys.any((s) => !RegExp(r'^(Ctrl|Alt|Shift|[A-Z0-9]|F([1-9]|1[0-2]))$')
            .hasMatch(s))) {
      return null;
    }
    final primary = keys.difference({'Ctrl', 'Alt', 'Shift'});
    if (primary.length > 1 ||
        (primary.isEmpty && !(keys.contains('Ctrl') && keys.contains('Alt'))) ||
        (primary.length == 1 &&
            keys.length == 1 &&
            !primary.first.startsWith('F'))) {
      return null;
    }
    return FloadeMouseShortcut._(keys);
  }

  String get label => [
        for (final key in ['Ctrl', 'Alt', 'Shift'])
          if (keys.contains(key)) key,
        ...keys.difference({'Ctrl', 'Alt', 'Shift'}),
      ].join('+');

  static String keyName(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight) return 'Ctrl';
    if (key == LogicalKeyboardKey.altLeft) return 'Alt';
    if (key == LogicalKeyboardKey.altRight) return 'AltGr';
    if (key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight) return 'Meta';
    if (key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight) return 'Shift';
    return key.keyLabel.toUpperCase();
  }
}

class FloadeMouseShortcutLatch {
  final _down = <LogicalKeyboardKey>{};
  final _blocked = <LogicalKeyboardKey>{};

  bool handle(LogicalKeyboardKey key, bool down, FloadeMouseShortcut shortcut,
      void Function() toggle) {
    if (!down) {
      _down.remove(key);
      return _blocked.remove(key);
    }
    if (!_down.add(key)) return _blocked.contains(key);
    final held = _down.map(FloadeMouseShortcut.keyName).toSet();
    final modifiers = {'Ctrl', 'Alt', 'Shift', 'Meta', 'AltGr'};
    final heldModifiers = held.intersection(modifiers);
    final requiredModifiers = shortcut.keys.intersection(modifiers);
    if (shortcut.keys.contains(FloadeMouseShortcut.keyName(key)) &&
        held.containsAll(shortcut.keys) &&
        heldModifiers.length == requiredModifiers.length &&
        heldModifiers.containsAll(requiredModifiers)) {
      _blocked.addAll(_down.where(
          (key) => shortcut.keys.contains(FloadeMouseShortcut.keyName(key))));
      toggle();
      return true;
    }
    return false;
  }

  void reset() {
    _down.clear();
    _blocked.clear();
  }
}
