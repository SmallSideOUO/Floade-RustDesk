import 'package:flutter/gestures.dart';

/// Flutter reports additional button presses as moves, even with a locked cursor.
class FloadeMouseButtons {
  static const supported = [
    kPrimaryMouseButton,
    kSecondaryMouseButton,
    kMiddleMouseButton,
    kBackMouseButton,
    kForwardMouseButton,
  ];

  int _held = 0;

  void update(int buttons, void Function(int button, bool down) send) {
    final previous = _held;
    _held = buttons;
    for (final button in supported) {
      if ((previous & button) != 0 && (buttons & button) == 0) {
        send(button, false);
      }
    }
    for (final button in supported) {
      if ((previous & button) == 0 && (buttons & button) != 0) {
        send(button, true);
      }
    }
  }

  void release(void Function(int button, bool down) send) => update(0, send);
}
