import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/utils/floade_mouse_shortcut.dart';

void main() {
  test('Ctrl+Alt toggles once in either order and consumes repeat and releases',
      () {
    final shortcut = FloadeMouseShortcut.parse('Ctrl+Alt')!;
    for (final pair in [
      [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.altLeft],
      [LogicalKeyboardKey.altLeft, LogicalKeyboardKey.controlRight],
    ]) {
      final latch = FloadeMouseShortcutLatch();
      var toggles = 0;
      bool event(LogicalKeyboardKey key, bool down) =>
          latch.handle(key, down, shortcut, () => toggles++);
      expect(event(pair[0], true), false);
      expect(event(pair[1], true), true);
      expect(event(pair[1], true), true);
      expect(toggles, 1);
      expect(event(pair[0], false), true);
      expect(event(pair[1], false), true);
      event(pair[0], true);
      event(pair[1], true);
      expect(toggles, 2);
    }
    final latch = FloadeMouseShortcutLatch();
    var toggles = 0;
    for (final key in [
      LogicalKeyboardKey.keyW,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.altLeft
    ]) {
      latch.handle(key, true, shortcut, () => toggles++);
    }
    expect(toggles, 1);
  });

  test(
      'custom shortcut waits for its primary key and rejects unsafe specifications',
      () {
    final shortcut = FloadeMouseShortcut.parse('Ctrl+Alt+M')!;
    final latch = FloadeMouseShortcutLatch();
    var toggles = 0;
    bool event(LogicalKeyboardKey key) =>
        latch.handle(key, true, shortcut, () => toggles++);
    event(LogicalKeyboardKey.controlLeft);
    expect(event(LogicalKeyboardKey.altLeft), false);
    expect(toggles, 0);
    expect(event(LogicalKeyboardKey.keyM), true);
    expect(toggles, 1);
    expect(FloadeMouseShortcut.parse('F8')?.label, 'F8');
    for (final invalid in ['', 'M', 'Ctrl', 'Ctrl+Ctrl+M', 'Ctrl+M+N', 'F13']) {
      expect(FloadeMouseShortcut.parse(invalid), null);
    }
    latch.reset();
    event(LogicalKeyboardKey.shiftLeft);
    event(LogicalKeyboardKey.controlLeft);
    event(LogicalKeyboardKey.altLeft);
    expect(event(LogicalKeyboardKey.keyM), false);
    expect(toggles, 1);
  });
}
