// Runs testvectors/blueline_processing_v1.json and checks the processing classes.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:blueline_sdk/blueline_core.dart';
import 'package:flutter_test/flutter_test.dart';

const fs = 250.0;
final Map<String, dynamic> vectors =
    jsonDecode(File('../testvectors/blueline_processing_v1.json').readAsStringSync()) as Map<String, dynamic>;

List<double> doubles(Object? list) => [for (final v in list as List) (v as num).toDouble()];

void expectClose(List<double> actual, List<double> expected, String name) {
  expect(actual.length, expected.length, reason: '$name: length');
  final tol = 1e-9 * math.max(1e-12, expected.map((v) => v.abs()).reduce(math.max));
  for (var i = 0; i < expected.length; i++) {
    if ((actual[i] - expected[i]).abs() > tol) fail('$name[$i]: expected ${expected[i]}, got ${actual[i]}');
  }
}

List<EegBand> bands() {
  final b = vectors['bands'] as Map<String, dynamic>;
  return [for (final e in b.entries) EegBand(e.key, doubles(e.value)[0], doubles(e.value)[1])];
}

List<double> ordered(Object? map, List<EegBand> bands) =>
    [for (final b in bands) ((map as Map<String, dynamic>)[b.name] as num).toDouble()];

BlueLineSignalPacket packet(int session, int first, List<List<int>> rows, {bool gap = false}) =>
    BlueLineSignalPacket(gapBefore: gap, session: session, firstIndex: first, samples: rows, microvoltsPerCount: 1);

void main() {
  group('shared vectors', () {
    test('filters', () {
      for (final c in (vectors['filters'] as List).cast<Map<String, dynamic>>()) {
        final name = c['name'] as String;
        final sr = (c['sampleRate'] as num).toDouble();
        final freq = (c['frequency'] as num).toDouble();
        final f = switch (c['type']) {
          'lowpass' => BlueLineFilter.lowpass(sr, freq, order: c['order'] as int),
          'highpass' => BlueLineFilter.highpass(sr, freq, order: c['order'] as int),
          'notch' => BlueLineFilter.notch(sr, frequency: freq, quality: (c['quality'] as num).toDouble()),
          _ => throw StateError('unknown filter type'),
        };
        expectClose([for (final s in f.sections) ...s.coefficients],
            [for (final s in c['sections'] as List) ...doubles(s)], '$name coefficients');
        expectClose(f.filterAll(doubles(c['input'])), doubles(c['output']), name);
      }
    });

    test('default signal filter', () {
      final c = vectors['signalFilterDefault'] as Map<String, dynamic>;
      final filter = SignalFilter(1, sampleRate: (c['sampleRate'] as num).toDouble());
      final out = filter.filterRows([for (final v in doubles(c['input'])) [v]]).map((r) => r[0]).toList();
      expectClose(out, doubles(c['output']), 'default chain');
    });

    test('spectrum', () {
      final b = bands();
      for (final c in (vectors['spectrum'] as List).cast<Map<String, dynamic>>()) {
        final name = c['name'] as String;
        final s = BlueLineSpectrum.powerSpectrum(doubles(c['input']), (c['sampleRate'] as num).toDouble(),
            nfft: c['nfft'] as int, maxFrequency: (c['maxFrequency'] as num).toDouble());
        expectClose(s.frequencies, doubles(c['frequencies']), '$name frequencies');
        expectClose(s.psd, doubles(c['psd']), '$name psd');
        final powers = BlueLineSpectrum.bandPowers(s, bands: b);
        expectClose([for (final x in b) powers[x.name]!], ordered(c['bandPowers'], b), '$name powers');
        if (c.containsKey('relative')) {
          final rel = BlueLineSpectrum.relativePowers(powers, bands: b);
          expectClose([for (final x in b) rel[x.name]!], ordered(c['relative'], b), '$name relative');
          final norm = BlueLineSpectrum.relativePowers(powers, bands: b, normalizeByBandwidth: true);
          expectClose([for (final x in b) norm[x.name]!], ordered(c['relativeNormalizedByBandwidth'], b),
              '$name relative normalized');
        }
      }
    });
  });

  test('filter responses', () {
    final notch = BlueLineFilter.notch(fs);
    expect(notch.response(50, fs), lessThan(1e-6));
    expect(notch.response(10, fs), closeTo(1, 0.01));
    for (final order in [2, 4, 6, 8]) {
      expect(BlueLineFilter.lowpass(fs, 40, order: order).response(40, fs), closeTo(math.sqrt(0.5), 1e-9));
      expect(BlueLineFilter.highpass(fs, 0.5, order: order).response(0.5, fs), closeTo(math.sqrt(0.5), 1e-9));
    }
    final offset = BlueLineFilter.highpass(fs, 0.5).filterAll(List.filled(500, 10000.0));
    expect(offset.map((v) => v.abs()).reduce(math.max), lessThan(1e-6));
  });

  test('invalid parameters', () {
    expect(() => BlueLineFilter.lowpass(fs, 125), throwsA(isA<InvalidParameter>()));
    expect(() => BlueLineFilter.highpass(fs, 1, order: 3), throwsA(isA<InvalidParameter>()));
    expect(() => BlueLineFilter.bandpass(fs, 40, 1), throwsA(isA<InvalidParameter>()));
    expect(() => BlueLineFilter.notch(fs, quality: 0), throwsA(isA<InvalidParameter>()));
    expect(() => SpectrumAnalyzer(1, window: 0.01), throwsA(isA<InvalidParameter>()));
  });

  test('signal filter resets on gap and new session', () {
    final filter = SignalFilter(1);
    filter.process(packet(1, 0, List.filled(5, [0])));
    expect(filter.process(packet(1, 5, [[5000]]))[0][0].abs(), greaterThan(1e-3));
    expect(filter.process(packet(1, 20, [[5000]], gap: true))[0][0], closeTo(0, 1e-6));
    expect(filter.process(packet(2, 0, [[-300]]))[0][0], closeTo(0, 1e-6));
  });

  List<SpectrumFrame> feed(SpectrumAnalyzer an, int session, int first, int count, {bool gap = false}) {
    final frames = <SpectrumFrame>[];
    for (var i = 0; i < count; i += 10) {
      final rows = [
        for (var k = i; k < math.min(count, i + 10); k++)
          () {
            final v = (3000 * math.sin(2 * math.pi * 10 * (first + k) / fs)).truncate();
            return [v, -v];
          }(),
      ];
      frames.addAll(an.process(packet(session, first + i, rows, gap: gap && i == 0)));
    }
    return frames;
  }

  test('analyzer frames and restarts', () {
    final an = SpectrumAnalyzer(2);
    final frames = feed(an, 1, 0, 1500);
    expect(frames.map((f) => f.endIndex), [for (var i = 1000; i <= 1500; i += 50) i]);
    final last = frames.last;
    expect(last.endTime(fs), closeTo(6, 1e-12));
    expect(last.channels[0].relative['alpha'], greaterThan(0.99));
    expect(last.channels[0].powers['alpha'], closeTo(3000 * 3000 / 2, 3000 * 3000 / 2 * 0.01));
    expect(last.channels[1].relative.values.reduce((a, b) => a + b), closeTo(1, 1e-12));

    final restart = SpectrumAnalyzer(2);
    feed(restart, 1, 0, 900);
    expect(restart.fill, closeTo(0.9, 1e-12));
    expect(feed(restart, 1, 1000, 900, gap: true), isEmpty);
    expect(feed(restart, 2, 0, 990), isEmpty);
    expect(feed(restart, 2, 990, 10), hasLength(1));
  });
}
