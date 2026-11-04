/// BlueLine BLE protocol v1: UUIDs and packet parsers.
///
/// Pure Dart with no Bluetooth state, so the parsers can also decode recorded
/// notifications. Multi-byte fields are little-endian, except EEG samples, which
/// are signed 24-bit big-endian (ADS1299 native). See docs/PROTOCOL.md.
library;

import 'dart:typed_data';

/// Protocol constants and UUIDs (lowercase, 128-bit).
abstract final class BlueLineV1 {
  static const int protocolVersion = 1;

  static const String serviceUuid = '8e7c0001-7b4e-4c1e-af19-22a6f38d9b40';
  static const String infoUuid = '8e7c0002-7b4e-4c1e-af19-22a6f38d9b40';
  static const String signalUuid = '8e7c0003-7b4e-4c1e-af19-22a6f38d9b40';
  static const String memsUuid = '8e7c0004-7b4e-4c1e-af19-22a6f38d9b40';
  static const String statusUuid = '8e7c0005-7b4e-4c1e-af19-22a6f38d9b40';
  static const String controlUuid = '8e7c0006-7b4e-4c1e-af19-22a6f38d9b40';

  static const String batteryServiceUuid = '0000180f-0000-1000-8000-00805f9b34fb';
  static const String batteryLevelUuid = '00002a19-0000-1000-8000-00805f9b34fb';
  static const String deviceInformationServiceUuid = '0000180a-0000-1000-8000-00805f9b34fb';
  static const String serialNumberUuid = '00002a25-0000-1000-8000-00805f9b34fb';
  static const String firmwareRevisionUuid = '00002a26-0000-1000-8000-00805f9b34fb';

  /// Company id of the manufacturer data in the scan response.
  static const int companyId = 0xFFFF;

  static const int signalHeaderBytes = 8;
  static const int bytesPerChannelSample = 3;

  /// Answer opcode to a request written while the previous one was still running.
  static const int busyOpcode = 0xFF;

  /// Gains accepted by SET_GAIN. The device boots with 6.
  static const List<int> supportedGains = [1, 2, 4, 6, 8, 12, 24];
}

const int _u32Mask = 0xFFFFFFFF;

ByteData _view(List<int> data) {
  final bytes = data is Uint8List ? data : Uint8List.fromList(data);
  return ByteData.sublistView(bytes);
}

int _int24be(ByteData d, int o) {
  final v = (d.getUint8(o) << 16) | (d.getUint8(o + 1) << 8) | d.getUint8(o + 2);
  return (v & 0x800000) != 0 ? v - 0x1000000 : v;
}

String _hex32(int v) => (v & _u32Mask).toRadixString(16).toUpperCase().padLeft(8, '0');

// ------------------------------------------------------------------ advertisement

/// Manufacturer data in the scan response: `'B' 'L' model(u8) chipIdLow(u32)`.
final class BlueLineAdvertisement {
  const BlueLineAdvertisement({required this.model, required this.chipIdLow});

  /// Model number, e.g. 4 = BlueLine-4.
  final int model;

  /// Bits 0..31 of the chip id: tells devices apart before connecting.
  final int chipIdLow;

  /// Parses the bytes after the company id (flutter_blue_plus's `manufacturerData[0xFFFF]`).
  static BlueLineAdvertisement? fromCompanyPayload(List<int>? payload) {
    if (payload == null || payload.length < 7 || payload[0] != 0x42 || payload[1] != 0x4C) return null;
    return BlueLineAdvertisement(model: payload[2], chipIdLow: _view(payload).getUint32(3, Endian.little));
  }

  /// Parses full manufacturer data including the 2-byte company id.
  static BlueLineAdvertisement? fromManufacturerData(List<int>? data) {
    if (data == null || data.length < 9 || _view(data).getUint16(0, Endian.little) != BlueLineV1.companyId) {
      return null;
    }
    return fromCompanyPayload(data.sublist(2));
  }

  @override
  bool operator ==(Object other) =>
      other is BlueLineAdvertisement && other.model == model && other.chipIdLow == chipIdLow;

  @override
  int get hashCode => Object.hash(model, chipIdLow);

  @override
  String toString() => 'BlueLineAdvertisement(model: $model, chipIdLow: ${_hex32(chipIdLow)})';
}

// ------------------------------------------------------------------ info

/// Capabilities from the Info `features` bitmask.
enum BlueLineFeature {
  signal(1 << 0),
  mems(1 << 1),

  /// Impedance measurement (reserved; not implemented by firmware 0.3.x).
  resist(1 << 2),
  identify(1 << 3),
  setGain(1 << 4);

  const BlueLineFeature(this.bit);

  final int bit;
}

/// Static device description read once after connecting (32 bytes).
final class BlueLineInfo {
  const BlueLineInfo({
    required this.protocolVersion,
    required this.model,
    required this.hasFactorySerial,
    required this.channelCount,
    required this.firmwareMajor,
    required this.firmwareMinor,
    required this.firmwarePatch,
    required this.adcBits,
    required this.adcRateHz,
    required this.signalRateHz,
    required this.decimation,
    required this.gain,
    required this.vrefMicrovolts,
    required this.memsRateHz,
    required this.maxSamplesPerPacket,
    required this.signalHeaderBytes,
    required this.featureBits,
    required this.chipIdHigh,
    required this.chipIdLow,
  });

  static const int byteCount = 32;

  final int protocolVersion;
  final int model;

  /// The Device Information serial number is a factory serial (otherwise the chip id).
  final bool hasFactorySerial;
  final int channelCount;
  final int firmwareMajor;
  final int firmwareMinor;
  final int firmwarePatch;
  final int adcBits;
  final int adcRateHz;

  /// EEG output rate (250 Hz).
  final int signalRateHz;

  /// ADC samples averaged per output sample (4).
  final int decimation;

  /// Current PGA gain; `BlueLineDevice.info` follows `setGain`.
  final int gain;
  final int vrefMicrovolts;
  final int memsRateHz;
  final int maxSamplesPerPacket;
  final int signalHeaderBytes;
  final int featureBits;

  /// Bits 32..63 and 0..31 of the 64-bit chip id (FICR DEVICEID). Two halves so the
  /// value is exact on every platform, including the web.
  final int chipIdHigh;
  final int chipIdLow;

  Set<BlueLineFeature> get features => {
        for (final f in BlueLineFeature.values)
          if (featureBits & f.bit != 0) f,
      };

  bool supports(BlueLineFeature feature) => featureBits & feature.bit != 0;

  String get firmwareVersion => '$firmwareMajor.$firmwareMinor.$firmwarePatch';

  /// 16 uppercase hex characters, as the serial reports it without a factory serial.
  String get chipIdHex => _hex32(chipIdHigh) + _hex32(chipIdLow);

  /// µV = code × vref_µV / (gain × 2^23).
  double get microvoltsPerCount => vrefMicrovolts / (gain * 8388608.0);

  /// Fields the decoder relies on match this SDK.
  bool get isSupported =>
      protocolVersion == BlueLineV1.protocolVersion &&
      signalHeaderBytes == BlueLineV1.signalHeaderBytes &&
      supports(BlueLineFeature.signal);

  BlueLineInfo withGain(int gain) => BlueLineInfo(
        protocolVersion: protocolVersion,
        model: model,
        hasFactorySerial: hasFactorySerial,
        channelCount: channelCount,
        firmwareMajor: firmwareMajor,
        firmwareMinor: firmwareMinor,
        firmwarePatch: firmwarePatch,
        adcBits: adcBits,
        adcRateHz: adcRateHz,
        signalRateHz: signalRateHz,
        decimation: decimation,
        gain: gain,
        vrefMicrovolts: vrefMicrovolts,
        memsRateHz: memsRateHz,
        maxSamplesPerPacket: maxSamplesPerPacket,
        signalHeaderBytes: signalHeaderBytes,
        featureBits: featureBits,
        chipIdHigh: chipIdHigh,
        chipIdLow: chipIdLow,
      );

  /// Returns null for short or malformed data (zero channels, rate, gain or reference).
  static BlueLineInfo? parse(List<int>? data) {
    if (data == null || data.length < byteCount) return null;
    final d = _view(data);
    final info = BlueLineInfo(
      protocolVersion: d.getUint8(0),
      model: d.getUint8(1),
      hasFactorySerial: d.getUint8(2) & 0x01 != 0,
      channelCount: d.getUint8(3),
      firmwareMajor: d.getUint8(4),
      firmwareMinor: d.getUint8(5),
      firmwarePatch: d.getUint8(6),
      adcBits: d.getUint8(7),
      adcRateHz: d.getUint16(8, Endian.little),
      signalRateHz: d.getUint16(10, Endian.little),
      decimation: d.getUint8(12),
      gain: d.getUint8(13),
      vrefMicrovolts: d.getUint32(14, Endian.little),
      memsRateHz: d.getUint16(18, Endian.little),
      maxSamplesPerPacket: d.getUint8(20),
      signalHeaderBytes: d.getUint8(21),
      featureBits: d.getUint16(22, Endian.little),
      chipIdLow: d.getUint32(24, Endian.little),
      chipIdHigh: d.getUint32(28, Endian.little),
    );
    if (info.channelCount <= 0 || info.signalRateHz <= 0 || info.gain <= 0 || info.vrefMicrovolts <= 0) return null;
    return info;
  }

  @override
  String toString() => 'BlueLineInfo(model: $model, firmware: $firmwareVersion, channels: $channelCount, '
      '$signalRateHz Hz, gain: $gain, chip: $chipIdHex)';
}

// ------------------------------------------------------------------ signal

/// One EEG notification: up to 19 consecutive samples of every channel.
///
/// Sample `i` has index `firstIndex + i` and time `index / signalRateHz` seconds
/// since START_SIGNAL of its [session].
final class BlueLineSignalPacket {
  const BlueLineSignalPacket({
    required this.gapBefore,
    required this.session,
    required this.firstIndex,
    required this.samples,
    this.microvoltsPerCount = 0,
  });

  /// Samples before [firstIndex] were lost: on the device, over BLE, or because the
  /// app did not consume packets fast enough. Do not interpolate silently.
  final bool gapBefore;
  final int session;

  /// Sample index of the first sample since START_SIGNAL (unsigned 32-bit).
  final int firstIndex;

  /// Raw signed 24-bit ADC counts as `[sample][channel]`.
  final List<List<int>> samples;

  /// Scale of this packet's session; 0 if unknown (parsed without a tracker).
  final double microvoltsPerCount;

  int get sampleCount => samples.length;
  int get channelCount => samples.isEmpty ? 0 : samples.first.length;

  /// Index of the sample after this packet (wraps at 2^32).
  int get nextIndex => (firstIndex + samples.length) & _u32Mask;

  /// Samples in microvolts as `[sample][channel]`.
  List<List<double>> get microvolts =>
      [for (final row in samples) [for (final v in row) v * microvoltsPerCount]];

  BlueLineSignalPacket copyWith({bool? gapBefore, double? microvoltsPerCount}) => BlueLineSignalPacket(
        gapBefore: gapBefore ?? this.gapBefore,
        session: session,
        firstIndex: firstIndex,
        samples: samples,
        microvoltsPerCount: microvoltsPerCount ?? this.microvoltsPerCount,
      );

  /// Returns null unless the length is exactly `8 + count × channelCount × 3`.
  static BlueLineSignalPacket? parse(List<int>? data, int channelCount) {
    const header = BlueLineV1.signalHeaderBytes;
    if (data == null || channelCount <= 0 || data.length <= header) return null;
    final d = _view(data);
    final count = d.getUint8(1);
    final stride = channelCount * BlueLineV1.bytesPerChannelSample;
    if (count <= 0 || data.length != header + count * stride) return null;
    return BlueLineSignalPacket(
      gapBefore: d.getUint8(0) & 0x01 != 0,
      session: d.getUint16(2, Endian.little),
      firstIndex: d.getUint32(4, Endian.little),
      samples: List.generate(
        count,
        (s) => List.generate(
            channelCount, (c) => _int24be(d, header + s * stride + c * BlueLineV1.bytesPerChannelSample),
            growable: false),
        growable: false,
      ),
    );
  }

  @override
  String toString() =>
      'BlueLineSignalPacket(session: $session, firstIndex: $firstIndex, samples: $sampleCount, gapBefore: $gapBefore)';
}

// ------------------------------------------------------------------ mems

/// One accelerometer sample (ADXL345, 100 Hz, raw counts, gravity included). 16 bytes.
final class BlueLineMemsSample {
  const BlueLineMemsSample({
    required this.session,
    required this.memsIndex,
    required this.signalIndex,
    required this.x,
    required this.y,
    required this.z,
  });

  static const int byteCount = 16;

  /// ADXL345 full resolution: 3.9 mg per count.
  static const double gPerCount = 0.0039;

  final int session;
  final int memsIndex;

  /// EEG sample index when this sample was read; null while the signal is stopped.
  /// Approximate alignment, not a hardware-synchronized timestamp.
  final int? signalIndex;
  final int x;
  final int y;
  final int z;

  double get xG => x * gPerCount;
  double get yG => y * gPerCount;
  double get zG => z * gPerCount;

  static BlueLineMemsSample? parse(List<int>? data) {
    if (data == null || data.length < byteCount) return null;
    final d = _view(data);
    final signalIndex = d.getUint32(6, Endian.little);
    return BlueLineMemsSample(
      session: d.getUint16(0, Endian.little),
      memsIndex: d.getUint32(2, Endian.little),
      signalIndex: signalIndex == _u32Mask ? null : signalIndex,
      x: d.getInt16(10, Endian.little),
      y: d.getInt16(12, Endian.little),
      z: d.getInt16(14, Endian.little),
    );
  }

  @override
  String toString() => 'BlueLineMemsSample(session: $session, index: $memsIndex, x: $x, y: $y, z: $z)';
}

// ------------------------------------------------------------------ status

enum BlueLineStatusFlag {
  memsOn(1 << 0),

  /// The BLE TX queue was full; signal samples are being dropped.
  txBlocked(1 << 1),
  adsFault(1 << 2),
  adxlFault(1 << 3);

  const BlueLineStatusFlag(this.bit);

  final int bit;
}

/// Device state and per-session loss counters (20 bytes). State, flag and gain
/// changes notify immediately; counter-only changes at most once per second.
final class BlueLineStatus {
  const BlueLineStatus({
    required this.isStreaming,
    required this.flagBits,
    required this.batteryPercent,
    required this.gain,
    required this.mtu,
    required this.session,
    required this.signalSamplesDropped,
    required this.adcFramesLost,
    required this.memsSamplesDropped,
  });

  static const int byteCount = 20;

  final bool isStreaming;
  final int flagBits;
  final int batteryPercent;
  final int gain;

  /// Effective ATT MTU.
  final int mtu;
  final int session;

  /// Samples dropped because the BLE queue was full, this session.
  final int signalSamplesDropped;

  /// ADC frames lost before processing, this session.
  final int adcFramesLost;
  final int memsSamplesDropped;

  Set<BlueLineStatusFlag> get flags => {
        for (final f in BlueLineStatusFlag.values)
          if (flagBits & f.bit != 0) f,
      };

  bool has(BlueLineStatusFlag flag) => flagBits & flag.bit != 0;

  static BlueLineStatus? parse(List<int>? data) {
    if (data == null || data.length < byteCount) return null;
    final d = _view(data);
    return BlueLineStatus(
      isStreaming: d.getUint8(0) == 1,
      flagBits: d.getUint8(1),
      batteryPercent: d.getUint8(2),
      gain: d.getUint8(3),
      mtu: d.getUint16(4, Endian.little),
      session: d.getUint16(6, Endian.little),
      signalSamplesDropped: d.getUint32(8, Endian.little),
      adcFramesLost: d.getUint32(12, Endian.little),
      memsSamplesDropped: d.getUint32(16, Endian.little),
    );
  }

  @override
  String toString() => 'BlueLineStatus(streaming: $isStreaming, battery: $batteryPercent%, gain: $gain, '
      'session: $session, dropped: $signalSamplesDropped, flags: ${flags.map((f) => f.name).join(',')})';
}

// ------------------------------------------------------------------ control

/// Control opcodes.
enum BlueLineCommand {
  startSignal(0x01),
  stopSignal(0x02),
  startMems(0x03),
  stopMems(0x04),
  startResist(0x05),
  stopResist(0x06),
  setGain(0x10),
  identify(0x20);

  const BlueLineCommand(this.opcode);

  final int opcode;

  /// Request bytes: `[opcode] [params...]`.
  Uint8List request([List<int> params = const []]) => Uint8List.fromList([opcode, ...params]);
}

/// Control result codes.
enum BlueLineResult {
  ok(0),
  notSupported(1),
  invalidParam(2),
  invalidState(3),
  busy(4),
  hardwareFault(5);

  const BlueLineResult(this.code);

  final int code;

  static BlueLineResult? fromCode(int code) {
    for (final r in values) {
      if (r.code == code) return r;
    }
    return null;
  }
}

/// Control notification: `[opcode] [result] [payload...]`.
final class BlueLineControlResponse {
  const BlueLineControlResponse({required this.opcode, required this.rawResult, required this.payload});

  final int opcode;
  final int rawResult;
  final Uint8List payload;

  BlueLineResult? get result => BlueLineResult.fromCode(rawResult);

  bool get isOk => rawResult == BlueLineResult.ok.code;

  /// START_SIGNAL: session u16. SET_GAIN: gain u8, session u16. Null otherwise.
  int? get session {
    final int offset;
    if (opcode == BlueLineCommand.startSignal.opcode) {
      offset = 0;
    } else if (opcode == BlueLineCommand.setGain.opcode) {
      offset = 1;
    } else {
      return null;
    }
    if (payload.length < offset + 2) return null;
    return payload[offset] | (payload[offset + 1] << 8);
  }

  /// True if this answers [command] (or is the BUSY answer to any request).
  bool answers(BlueLineCommand command) => opcode == command.opcode || opcode == BlueLineV1.busyOpcode;

  static BlueLineControlResponse? parse(List<int>? data) {
    if (data == null || data.length < 2) return null;
    return BlueLineControlResponse(
        opcode: data[0], rawResult: data[1], payload: Uint8List.fromList(data.sublist(2)));
  }
}
