/// EEG signal processing: filters, spectrum and band powers.
///
/// The same algorithms as the other BlueLine SDKs, checked by
/// testvectors/blueline_processing_v1.json. Pure Dart. The classes keep state:
/// feed each from one stream subscription.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'errors.dart';
import 'protocol.dart';

/// An EEG frequency band in Hz, `low <= f < high`.
final class EegBand {
  const EegBand(this.name, this.low, this.high) : assert(low < high);

  final String name;
  final double low;
  final double high;

  double get width => high - low;

  /// delta 1–4, theta 4–8, alpha 8–13, beta 13–30, gamma 30–45 Hz.
  static const List<EegBand> defaults = [
    EegBand('delta', 1, 4),
    EegBand('theta', 4, 8),
    EegBand('alpha', 8, 13),
    EegBand('beta', 13, 30),
    EegBand('gamma', 30, 45),
  ];
}

// ------------------------------------------------------------------ filters

/// One second-order IIR section (direct form II transposed), `a0 == 1`.
///
/// Starts in the steady state of its first input sample, so a large electrode
/// offset does not ring through a high-pass filter.
final class Biquad {
  Biquad(this.b0, this.b1, this.b2, this.a1, this.a2);

  final double b0, b1, b2, a1, a2;
  double _s1 = 0, _s2 = 0;
  bool _started = false;

  double get dcGain => (b0 + b1 + b2) / (1 + a1 + a2);

  /// `[b0, b1, b2, a1, a2]`.
  List<double> get coefficients => [b0, b1, b2, a1, a2];

  /// Forgets the past; the next sample sets the starting state again.
  void reset() {
    _s1 = 0;
    _s2 = 0;
    _started = false;
  }

  double filter(double x) {
    if (!_started) {
      final g = dcGain;
      _s2 = (b2 - a2 * g) * x;
      _s1 = (b1 - a1 * g) * x + _s2;
      _started = true;
    }
    final y = b0 * x + _s1;
    _s1 = b1 * x - a1 * y + _s2;
    _s2 = b2 * x - a2 * y;
    return y;
  }

  double _response(double frequency, double sampleRate) {
    final w = 2 * math.pi * frequency / sampleRate;
    final c1 = math.cos(w), n1 = -math.sin(w), c2 = math.cos(2 * w), n2 = -math.sin(2 * w);
    final nr = b0 + b1 * c1 + b2 * c2, ni = b1 * n1 + b2 * n2;
    final dr = 1 + a1 * c1 + a2 * c2, di = a1 * n1 + a2 * n2;
    return math.sqrt(nr * nr + ni * ni) / math.sqrt(dr * dr + di * di);
  }

  Biquad _copy() => Biquad(b0, b1, b2, a1, a2);
}

/// A cascade of biquads for one channel. Build one with the named constructors.
final class BlueLineFilter {
  BlueLineFilter(List<Biquad> sections, [this.name = 'custom']) : sections = List.unmodifiable(sections);

  /// Butterworth low-pass; [order] 2, 4, 6 or 8 (-3 dB at [cutoff]).
  factory BlueLineFilter.lowpass(double sampleRate, double cutoff, {int order = 4}) {
    final w0 = _omega(sampleRate, cutoff);
    return BlueLineFilter([for (final q in _butterworthQs(order)) _section(w0, q, low: true)],
        'lowpass ${_fmt(cutoff)} Hz');
  }

  /// Butterworth high-pass; removes the electrode offset and slow drift.
  factory BlueLineFilter.highpass(double sampleRate, double cutoff, {int order = 4}) {
    final w0 = _omega(sampleRate, cutoff);
    return BlueLineFilter([for (final q in _butterworthQs(order)) _section(w0, q, low: false)],
        'highpass ${_fmt(cutoff)} Hz');
  }

  /// Narrow band-stop for mains: 50 Hz (Europe, Turkey) or 60 Hz. -3 dB width = frequency / quality.
  factory BlueLineFilter.notch(double sampleRate, {double frequency = 50, double quality = 30}) {
    final w0 = _omega(sampleRate, frequency);
    if (quality <= 0) throw const InvalidParameter('quality must be positive');
    final g = 1 / (1 + math.tan(w0 / quality / 2));
    final c = math.cos(w0);
    return BlueLineFilter([Biquad(g, -2 * g * c, g, -2 * g * c, 2 * g - 1)], 'notch ${_fmt(frequency)} Hz');
  }

  /// High-pass at [low] followed by low-pass at [high].
  factory BlueLineFilter.bandpass(double sampleRate, double low, double high, {int order = 4}) {
    if (!(low < high)) throw const InvalidParameter('low must be below high');
    final hp = BlueLineFilter.highpass(sampleRate, low, order: order);
    final lp = BlueLineFilter.lowpass(sampleRate, high, order: order);
    return BlueLineFilter([...hp.sections, ...lp.sections], 'bandpass ${_fmt(low)}-${_fmt(high)} Hz');
  }

  final List<Biquad> sections;
  final String name;

  void reset() {
    for (final s in sections) {
      s.reset();
    }
  }

  double filter(double x) {
    var v = x;
    for (final s in sections) {
      v = s.filter(v);
    }
    return v;
  }

  List<double> filterAll(Iterable<double> values) => [for (final v in values) filter(v)];

  /// Magnitude response (1.0 = passes unchanged) at [frequency].
  double response(double frequency, double sampleRate) =>
      sections.fold(1.0, (acc, s) => acc * s._response(frequency, sampleRate));

  /// Same coefficients, fresh state (for another channel).
  BlueLineFilter copy() => BlueLineFilter([for (final s in sections) s._copy()], name);

  @override
  String toString() => 'BlueLineFilter($name, ${sections.length} sections)';

  static String _fmt(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  static double _omega(double sampleRate, double frequency) {
    if (!(frequency > 0 && frequency < sampleRate / 2)) {
      throw InvalidParameter('frequency must be between 0 and ${sampleRate / 2} Hz (Nyquist), got $frequency');
    }
    return 2 * math.pi * frequency / sampleRate;
  }

  static List<double> _butterworthQs(int order) {
    if (order < 2 || order.isOdd) throw const InvalidParameter('order must be an even number >= 2');
    return [for (var k = 0; k < order ~/ 2; k++) 1 / (2 * math.cos(math.pi * (2 * k + 1) / (2 * order)))];
  }

  static Biquad _section(double w0, double q, {required bool low}) {
    final c = math.cos(w0);
    final alpha = math.sin(w0) / (2 * q);
    final a0 = 1 + alpha;
    final b = (low ? 1 - c : 1 + c) / 2 / a0;
    return Biquad(b, low ? 2 * b : -2 * b, b, -2 * c / a0, (1 - alpha) / a0);
  }
}

/// Filters applied one after another to a single channel.
final class BlueLineFilterList {
  BlueLineFilterList([List<BlueLineFilter> filters = const []]) : filters = [...filters];

  final List<BlueLineFilter> filters;

  void add(BlueLineFilter filter) => filters.add(filter);

  void reset() {
    for (final f in filters) {
      f.reset();
    }
  }

  double filter(double x) {
    var v = x;
    for (final f in filters) {
      v = f.filter(v);
    }
    return v;
  }

  List<double> filterAll(Iterable<double> values) => [for (final v in values) filter(v)];

  double response(double frequency, double sampleRate) =>
      filters.fold(1.0, (acc, f) => acc * f.response(frequency, sampleRate));

  BlueLineFilterList copy() => BlueLineFilterList([for (final f in filters) f.copy()]);
}

/// Detects a new session or lost samples between packets.
final class _Continuity {
  int? _session;

  bool broken(BlueLineSignalPacket packet) {
    final broken = packet.gapBefore || packet.session != _session;
    _session = packet.session;
    return broken;
  }
}

/// The same filter chain on every channel of a stream.
///
/// Default: 0.5–40 Hz band-pass (4th-order Butterworth) and a 50 Hz notch. Pass
/// `notch: 60` in the Americas, `null` to leave a stage out, or your own
/// [filters] to replace the defaults.
final class SignalFilter {
  factory SignalFilter(
    int channelCount, {
    double sampleRate = 250,
    double? highpass = 0.5,
    double? lowpass = 40,
    double? notch = 50,
    int order = 4,
    List<BlueLineFilter>? filters,
  }) {
    final chain = filters?.map((f) => f.copy()).toList() ??
        [
          if (highpass != null) BlueLineFilter.highpass(sampleRate, highpass, order: order),
          if (lowpass != null) BlueLineFilter.lowpass(sampleRate, lowpass, order: order),
          if (notch != null) BlueLineFilter.notch(sampleRate, frequency: notch),
        ];
    final template = BlueLineFilterList(chain);
    return SignalFilter._(sampleRate, List.unmodifiable([for (var c = 0; c < channelCount; c++) template.copy()]));
  }

  SignalFilter._(this.sampleRate, this.channels);

  final double sampleRate;
  final List<BlueLineFilterList> channels;
  final _continuity = _Continuity();

  void reset() {
    for (final c in channels) {
      c.reset();
    }
  }

  /// Filters `[sample][channel]` values that continue the previous call.
  List<List<double>> filterRows(List<List<double>> rows) => [
        for (final row in rows) [for (var c = 0; c < row.length; c++) channels[c].filter(row[c])]
      ];

  /// Filtered microvolts of [packet] as `[sample][channel]`. Resets first when the
  /// packet starts a new session or follows lost samples; allow 1–2 s to settle.
  List<List<double>> process(BlueLineSignalPacket packet) {
    if (_continuity.broken(packet)) reset();
    return filterRows(packet.microvolts);
  }
}

// ------------------------------------------------------------------ spectrum

/// One-sided power spectral density: [psd] in µV²/Hz at [frequencies] (Hz).
final class PowerSpectrum {
  const PowerSpectrum(this.frequencies, this.psd);

  final List<double> frequencies;
  final List<double> psd;
}

abstract final class BlueLineSpectrum {
  /// Periodic Hann window.
  static List<double> hannWindow(int n) => [for (var i = 0; i < n; i++) 0.5 - 0.5 * math.cos(2 * math.pi * i / n)];

  /// PSD of one channel: mean removed, Hann window, zero-padded to [nfft]
  /// (default: next power of two), up to [maxFrequency] if given.
  /// Matches `scipy.signal.periodogram(x, fs, window="hann", nfft=nfft)`.
  static PowerSpectrum powerSpectrum(List<double> values, double sampleRate, {int? nfft, double? maxFrequency}) {
    final n = values.length;
    if (n < 2) throw const InvalidParameter('need at least 2 samples');
    var size = 1;
    while (size < n) {
      size <<= 1;
    }
    if (nfft != null) size = nfft;
    if (size < n || size & (size - 1) != 0) {
      throw const InvalidParameter('nfft must be a power of two and at least the number of values');
    }
    var mean = 0.0;
    for (final v in values) {
      mean += v;
    }
    mean /= n;
    final window = hannWindow(n);
    var windowPower = 0.0;
    for (final w in window) {
      windowPower += w * w;
    }
    final scale = 1 / (sampleRate * windowPower);
    final re = Float64List(size);
    final im = Float64List(size);
    for (var i = 0; i < n; i++) {
      re[i] = (values[i] - mean) * window[i];
    }
    _fft(re, im);
    final df = sampleRate / size;
    var bins = size ~/ 2 + 1;
    if (maxFrequency != null) {
      var keep = 0;
      for (var k = 0; k < bins; k++) {
        if (k * df <= maxFrequency) keep++;
      }
      bins = keep;
    }
    final psd = [
      for (var k = 0; k < bins; k++) (re[k] * re[k] + im[k] * im[k]) * scale * (k == 0 || k == size ~/ 2 ? 1 : 2)
    ];
    return PowerSpectrum([for (var k = 0; k < bins; k++) k * df], psd);
  }

  /// Power in each band (µV² for a µV spectrum): PSD summed over `low <= f < high` times the bin width.
  static Map<String, double> bandPowers(PowerSpectrum spectrum, {List<EegBand> bands = EegBand.defaults}) {
    final f = spectrum.frequencies;
    if (f.length < 2) return {};
    final df = f[1] - f[0];
    return {
      for (final band in bands)
        band.name: () {
          var sum = 0.0;
          for (var k = 0; k < f.length; k++) {
            if (f[k] >= band.low && f[k] < band.high) sum += spectrum.psd[k];
          }
          return sum * df;
        }(),
    };
  }

  /// Each band's share of the total, summing to 1. With [normalizeByBandwidth]
  /// each band is first divided by its width, so wide bands do not dominate.
  static Map<String, double> relativePowers(Map<String, double> powers,
      {List<EegBand> bands = EegBand.defaults, bool normalizeByBandwidth = false}) {
    final p = <String, double>{
      for (final band in bands)
        if (powers.containsKey(band.name)) band.name: normalizeByBandwidth ? powers[band.name]! / band.width : powers[band.name]!,
    };
    var total = 0.0;
    for (final v in p.values) {
      total += v;
    }
    return p.map((k, v) => MapEntry(k, total > 0 ? v / total : 0.0));
  }

  /// In-place radix-2 FFT.
  static void _fft(Float64List re, Float64List im) {
    final n = re.length;
    var j = 0;
    for (var i = 1; i < n; i++) {
      var bit = n >> 1;
      while (j & bit != 0) {
        j ^= bit;
        bit >>= 1;
      }
      j |= bit;
      if (i < j) {
        var t = re[i];
        re[i] = re[j];
        re[j] = t;
        t = im[i];
        im[i] = im[j];
        im[j] = t;
      }
    }
    for (var size = 2; size <= n; size *= 2) {
      final half = size ~/ 2;
      final step = -2 * math.pi / size;
      for (var k = 0; k < half; k++) {
        final wr = math.cos(step * k);
        final wi = math.sin(step * k);
        for (var start = k; start < n; start += size) {
          final a = start + half;
          final tr = wr * re[a] - wi * im[a];
          final ti = wr * im[a] + wi * re[a];
          re[a] = re[start] - tr;
          im[a] = im[start] - ti;
          re[start] += tr;
          im[start] += ti;
        }
      }
    }
  }
}

final class ChannelSpectrum {
  const ChannelSpectrum(this.psd, this.powers, this.relative);

  /// PSD in µV²/Hz at [SpectrumFrame.frequencies].
  final List<double> psd;

  /// Absolute band power in µV², by band name.
  final Map<String, double> powers;

  /// Share of each band in the total of all bands (sums to 1).
  final Map<String, double> relative;
}

/// Spectrum of the last window of every channel.
final class SpectrumFrame {
  const SpectrumFrame(this.session, this.endIndex, this.frequencies, this.channels);

  final int session;

  /// Index of the sample after the window.
  final int endIndex;
  final List<double> frequencies;
  final List<ChannelSpectrum> channels;

  /// Seconds since the session started at the end of the window.
  double endTime(double sampleRate) => endIndex / sampleRate;
}

/// Sliding-window spectrum and band powers of every channel.
///
/// Keeps the last [window] seconds (default 4 s = 1000 samples at 250 Hz) and
/// computes a [SpectrumFrame] [updateRate] times per second once the window is
/// full. After a new session or lost samples the window fills again, so a frame
/// never spans a gap. Feed it raw microvolts; the mean of each window is removed.
final class SpectrumAnalyzer {
  factory SpectrumAnalyzer(
    int channelCount, {
    double sampleRate = 250,
    double window = 4,
    double updateRate = 5,
    double maxFrequency = 50,
    List<EegBand> bands = EegBand.defaults,
    bool normalizeByBandwidth = false,
  }) {
    final windowSamples = (window * sampleRate).round();
    if (windowSamples < 16) throw const InvalidParameter('window too short');
    if (updateRate <= 0) throw const InvalidParameter('updateRate must be positive');
    return SpectrumAnalyzer._(channelCount, sampleRate, windowSamples, math.max(1, (sampleRate / updateRate).round()),
        maxFrequency, List.unmodifiable(bands), normalizeByBandwidth);
  }

  SpectrumAnalyzer._(this.channelCount, this.sampleRate, this.windowSamples, this.stepSamples, this.maxFrequency,
      this.bands, this.normalizeByBandwidth)
      : _ring = List.generate(channelCount, (_) => Float64List(windowSamples)),
        _untilNext = windowSamples;

  final int channelCount;
  final double sampleRate;
  final int windowSamples;
  final int stepSamples;
  final double maxFrequency;
  final List<EegBand> bands;
  final bool normalizeByBandwidth;
  final List<Float64List> _ring;
  int _count = 0;
  int _head = 0;
  int _untilNext;
  int _nextIndex = 0;
  final _continuity = _Continuity();

  /// How full the window is, 0.0–1.0.
  double get fill => _count / windowSamples;

  void reset() {
    _count = 0;
    _head = 0;
    _untilNext = windowSamples;
    _nextIndex = 0;
  }

  /// Adds a packet; returns the frames it completed (often none, sometimes one).
  List<SpectrumFrame> process(BlueLineSignalPacket packet) {
    if (_continuity.broken(packet)) reset();
    return addRows(packet.microvolts, session: packet.session, firstIndex: packet.firstIndex);
  }

  /// Adds `[sample][channel]` values that continue the previous call.
  List<SpectrumFrame> addRows(List<List<double>> rows, {int session = 0, int? firstIndex}) {
    var index = firstIndex ?? _nextIndex;
    final frames = <SpectrumFrame>[];
    for (final row in rows) {
      for (var c = 0; c < channelCount; c++) {
        _ring[c][_head] = row[c];
      }
      _head = (_head + 1) % windowSamples;
      if (_count < windowSamples) _count++;
      index = (index + 1) & 0xFFFFFFFF;
      if (--_untilNext <= 0) {
        _untilNext = stepSamples;
        frames.add(_compute(session, index));
      }
    }
    _nextIndex = index;
    return frames;
  }

  SpectrumFrame _compute(int session, int endIndex) {
    var frequencies = const <double>[];
    final channels = [
      for (final buf in _ring)
        () {
          // oldest sample first
          final ordered = [for (var i = 0; i < windowSamples; i++) buf[(_head + i) % windowSamples]];
          final spectrum = BlueLineSpectrum.powerSpectrum(ordered, sampleRate, maxFrequency: maxFrequency);
          frequencies = spectrum.frequencies;
          final powers = BlueLineSpectrum.bandPowers(spectrum, bands: bands);
          return ChannelSpectrum(spectrum.psd, powers,
              BlueLineSpectrum.relativePowers(powers, bands: bands, normalizeByBandwidth: normalizeByBandwidth));
        }(),
    ];
    return SpectrumFrame(session, endIndex, frequencies, channels);
  }
}
