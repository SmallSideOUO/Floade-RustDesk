import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/utils/floade_mouse_buttons.dart';

void main() {
  test('left and right holds release independently, including stationary moves',
      () {
    final buttons = FloadeMouseButtons();
    final events = <String>[];
    void send(int button, bool down) => events.add('$button:$down');
    buttons.update(kPrimaryMouseButton, send);
    buttons.update(kPrimaryMouseButton | kSecondaryMouseButton, send);
    buttons.update(kPrimaryMouseButton | kSecondaryMouseButton, send);
    buttons.update(kSecondaryMouseButton, send);
    expect(events, ['1:true', '2:true', '1:false']);
    buttons.update(0, send);
    expect(events.last, '2:false');
  });

  test('multiple changed bits are sent separately in either press order', () {
    final buttons = FloadeMouseButtons();
    final events = <String>[];
    void send(int button, bool down) => events.add('$button:$down');
    buttons.update(kSecondaryMouseButton, send);
    buttons.update(
        kPrimaryMouseButton | kSecondaryMouseButton | kMiddleMouseButton, send);
    buttons.update(kPrimaryMouseButton, send);
    expect(events, ['2:true', '1:true', '4:true', '2:false', '4:false']);
  });

  test('focus loss or mode exit releases all held buttons once', () {
    final buttons = FloadeMouseButtons();
    final events = <String>[];
    void send(int button, bool down) => events.add('$button:$down');
    buttons.update(
        kPrimaryMouseButton | kSecondaryMouseButton | kBackMouseButton, send);
    events.clear();
    buttons.release(send);
    buttons.release(send);
    expect(events, ['1:false', '2:false', '8:false']);
    buttons.update(kSecondaryMouseButton, send);
    expect(events.last, '2:true');
  });
}
