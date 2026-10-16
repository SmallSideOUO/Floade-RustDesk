import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/utils/floade_raw_mouse.dart';

void main() {
  const channel = MethodChannel('floade/raw_mouse');
  testWidgets('raw counts are unchanged by DPI, position or recenter events', (tester) async {
    final samples = <List<dynamic>>[[640, -320, true], [0, 0, true]];
    final deltas = <List<int>>[];
    var disabled = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'enable') return true;
      if (call.method == 'disable') { disabled = true; return null; }
      return samples.isEmpty ? [0, 0, true] : samples.removeAt(0);
    });
    final mouse = FloadeRawMouse();
    expect(await mouse.start((x, y) => deltas.add([x, y]), () => fail('capture lost')), true);
    await tester.pump(const Duration(milliseconds: 8));
    await tester.pump(const Duration(milliseconds: 8));
    expect(deltas, [[640, -320]]);
    mouse.stop();
    await tester.pump();
    expect(disabled, true);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('losing native focus stops capture and releases the cursor', (tester) async {
    var lost = 0;
    var disabled = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'enable') return true;
      if (call.method == 'disable') { disabled = true; return null; }
      return [0, 0, false];
    });
    final mouse = FloadeRawMouse();
    expect(await mouse.start((_, __) => fail('unexpected movement'), () => lost++), true);
    await tester.pump(const Duration(milliseconds: 8));
    expect(lost, 1);
    expect(disabled, true);
    await tester.pump(const Duration(milliseconds: 80));
    expect(lost, 1);
    mouse.stop();
    await tester.pump();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });
}
