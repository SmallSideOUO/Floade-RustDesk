import 'dart:async';
import 'package:flutter/services.dart';

class FloadeRawMouse {
  static const _channel = MethodChannel('floade/raw_mouse');
  Timer? _timer;
  int _generation = 0;

  Future<bool> start(void Function(int, int) onDelta, void Function() onLost) async {
    final generation = ++_generation;
    final enabled = await _channel.invokeMethod<bool>('enable') == true;
    if (generation != _generation) return false;
    if (!enabled) return false;
    Future<void> read() async {
      if (generation != _generation) return;
      try {
        final data = await _channel.invokeListMethod<dynamic>('read');
        if (generation != _generation) return;
        if (data == null || data.length != 3 || data[2] != true) {
          stop();
          onLost();
          return;
        }
        final dx = data[0] as int;
        final dy = data[1] as int;
        if (dx != 0 || dy != 0) onDelta(dx, dy);
        _timer = Timer(const Duration(milliseconds: 8), read);
      } catch (_) {
        if (generation != _generation) return;
        stop();
        onLost();
      }
    }
    _timer = Timer(const Duration(milliseconds: 8), read);
    return true;
  }

  void stop() {
    ++_generation;
    _timer?.cancel();
    _timer = null;
    _channel.invokeMethod<void>('disable').catchError((Object _) {});
  }
}
