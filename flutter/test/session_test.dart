// Session and gap tracking (same cases as Android and Python).
import 'package:blueline_sdk/blueline_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 1-channel Signal notification with [count] samples of [value].
List<int> packet(int session, int firstIndex, {int count = 5, bool firmwareGap = false, int value = 0}) {
  final v = value & 0xFFFFFF;
  final i = firstIndex & 0xFFFFFFFF;
  return [
    firmwareGap ? 1 : 0, count, session & 0xFF, session >> 8,
    i & 0xFF, (i >> 8) & 0xFF, (i >> 16) & 0xFF, (i >> 24) & 0xFF,
    for (var s = 0; s < count; s++) ...[v >> 16, (v >> 8) & 0xFF, v & 0xFF],
  ];
}

void main() {
  test('drops packets before begin and of other sessions', () {
    final t = SignalSessionTracker(1);
    expect(t.accept(packet(1, 0)), isNull);
    t.begin(2, 0.5);
    expect(t.accept(packet(1, 0)), isNull);
    final p = t.accept(packet(2, 0));
    expect(p, isNotNull);
    expect(p!.microvoltsPerCount, 0.5);
    t.end();
    expect(t.accept(packet(2, 5)), isNull);
  });

  test('marks a gap when the index does not continue', () {
    final t = SignalSessionTracker(1)..begin(7, 1);
    expect(t.accept(packet(7, 0))!.gapBefore, isFalse);
    expect(t.accept(packet(7, 5))!.gapBefore, isFalse);
    expect(t.accept(packet(7, 15))!.gapBefore, isTrue); // 10..14 lost
    expect(t.accept(packet(7, 20))!.gapBefore, isFalse);
  });

  test('keeps firmware and app gaps', () {
    final t = SignalSessionTracker(1)..begin(1, 1);
    expect(t.accept(packet(1, 0, firmwareGap: true))!.gapBefore, isTrue);
    t.markGap();
    expect(t.accept(packet(1, 5))!.gapBefore, isTrue);
    expect(t.accept(packet(1, 10))!.gapBefore, isFalse);
  });

  test('index wraps at 32 bits', () {
    final t = SignalSessionTracker(1)..begin(1, 1);
    t.accept(packet(1, 0xFFFFFFFD, count: 3));
    expect(t.accept(packet(1, 0))!.gapBefore, isFalse);
  });

  test('begin resets index tracking', () {
    final t = SignalSessionTracker(1)..begin(1, 1);
    t.accept(packet(1, 100));
    t.begin(2, 2);
    expect(t.accept(packet(2, 0))!.gapBefore, isFalse);
  });

  test('microvolts use the session scale', () {
    final t = SignalSessionTracker(1)..begin(3, 0.25);
    final p = t.accept(packet(3, 0, count: 1, value: -2))!;
    expect(p.samples[0][0], -2);
    expect(p.microvolts[0][0], -0.5);
  });
}
