// Runs the shared test vectors (../testvectors/blueline_protocol_v1.json).
import 'dart:convert';
import 'dart:io';

import 'package:blueline_sdk/blueline_core.dart';
import 'package:flutter_test/flutter_test.dart';

final Map<String, dynamic> vectors =
    jsonDecode(File('../testvectors/blueline_protocol_v1.json').readAsStringSync()) as Map<String, dynamic>;

List<Map<String, dynamic>> cases(String name) => (vectors[name] as List).cast<Map<String, dynamic>>();

List<int> hex(String s) => [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

const features = {
  'signal': BlueLineFeature.signal,
  'mems': BlueLineFeature.mems,
  'resist': BlueLineFeature.resist,
  'identify': BlueLineFeature.identify,
  'setGain': BlueLineFeature.setGain,
};
const flags = {
  'memsOn': BlueLineStatusFlag.memsOn,
  'txBlocked': BlueLineStatusFlag.txBlocked,
  'adsFault': BlueLineStatusFlag.adsFault,
  'adxlFault': BlueLineStatusFlag.adxlFault,
};
const commands = {'startSignal': BlueLineCommand.startSignal, 'setGain': BlueLineCommand.setGain};

void main() {
  test('info', () {
    for (final c in cases('info')) {
      final info = BlueLineInfo.parse(hex(c['hex'] as String));
      final expect_ = c['expect'] as Map<String, dynamic>?;
      if (expect_ == null) {
        expect(info, isNull, reason: c['name'] as String);
        continue;
      }
      expect(info, isNotNull, reason: c['name'] as String);
      final values = <String, Object?>{
        'protocolVersion': info!.protocolVersion,
        'model': info.model,
        'hasFactorySerial': info.hasFactorySerial,
        'channelCount': info.channelCount,
        'firmwareVersion': info.firmwareVersion,
        'adcBits': info.adcBits,
        'adcRateHz': info.adcRateHz,
        'signalRateHz': info.signalRateHz,
        'decimation': info.decimation,
        'gain': info.gain,
        'vrefMicrovolts': info.vrefMicrovolts,
        'memsRateHz': info.memsRateHz,
        'maxSamplesPerPacket': info.maxSamplesPerPacket,
        'signalHeaderBytes': info.signalHeaderBytes,
        'featureBits': info.featureBits,
        'chipIdHex': info.chipIdHex,
        'isSupported': info.isSupported,
      };
      for (final e in expect_.entries) {
        final reason = '${c['name']}: ${e.key}';
        if (e.key == 'features') {
          expect(info.features, {for (final n in e.value as List) features[n]!}, reason: reason);
        } else if (e.key == 'microvoltsPerCount') {
          expect(info.microvoltsPerCount, closeTo(e.value as num, 1e-12), reason: reason);
        } else {
          expect(values.containsKey(e.key), isTrue, reason: 'unknown key ${e.key}');
          expect(values[e.key], e.value, reason: reason);
        }
      }
    }
  });

  test('signal', () {
    for (final c in cases('signal')) {
      final p = BlueLineSignalPacket.parse(hex(c['hex'] as String), c['channelCount'] as int);
      final e = c['expect'] as Map<String, dynamic>?;
      if (e == null) {
        expect(p, isNull, reason: c['name'] as String);
        continue;
      }
      expect(p!.gapBefore, e['gapBefore']);
      expect(p.session, e['session']);
      expect(p.firstIndex, e['firstIndex']);
      if (e.containsKey('sampleCount')) expect(p.sampleCount, e['sampleCount']);
      if (e.containsKey('samples')) expect(p.samples, e['samples']);
    }
  });

  test('mems', () {
    for (final c in cases('mems')) {
      final s = BlueLineMemsSample.parse(hex(c['hex'] as String));
      final e = c['expect'] as Map<String, dynamic>?;
      if (e == null) {
        expect(s, isNull, reason: c['name'] as String);
        continue;
      }
      expect(s!.session, e['session']);
      expect(s.memsIndex, e['memsIndex']);
      expect(s.signalIndex, e['signalIndex']);
      expect([s.x, s.y, s.z], [e['x'], e['y'], e['z']]);
      if (e.containsKey('zG')) expect(s.zG, closeTo(e['zG'] as num, 1e-9));
    }
  });

  test('status', () {
    for (final c in cases('status')) {
      final s = BlueLineStatus.parse(hex(c['hex'] as String));
      final e = c['expect'] as Map<String, dynamic>?;
      if (e == null) {
        expect(s, isNull, reason: c['name'] as String);
        continue;
      }
      expect(s!.flags, {for (final n in e['flags'] as List) flags[n]!});
      expect(s.isStreaming, e['isStreaming']);
      expect(s.batteryPercent, e['batteryPercent']);
      expect(s.gain, e['gain']);
      expect(s.mtu, e['mtu']);
      expect(s.session, e['session']);
      expect(s.signalSamplesDropped, e['signalSamplesDropped']);
      expect(s.adcFramesLost, e['adcFramesLost']);
      expect(s.memsSamplesDropped, e['memsSamplesDropped']);
    }
  });

  test('control requests', () {
    for (final c in cases('controlRequest')) {
      expect(commands[c['command']]!.request((c['params'] as List).cast<int>()), hex(c['hex'] as String));
    }
  });

  test('control responses', () {
    for (final c in cases('controlResponse')) {
      final r = BlueLineControlResponse.parse(hex(c['hex'] as String));
      final e = c['expect'] as Map<String, dynamic>?;
      if (e == null) {
        expect(r, isNull, reason: c['name'] as String);
        continue;
      }
      expect(r!.opcode, e['opcode']);
      expect(r.result?.name, e['result']);
      expect(r.session, e['session']);
    }
  });

  test('advertisement', () {
    for (final c in cases('advertisement')) {
      final full = hex(c['manufacturerDataHex'] as String);
      final fromFull = BlueLineAdvertisement.fromManufacturerData(full);
      final fromPayload = full.length >= 2 && full[0] == 0xFF && full[1] == 0xFF
          ? BlueLineAdvertisement.fromCompanyPayload(full.sublist(2))
          : null;
      final e = c['expect'] as Map<String, dynamic>?;
      if (e == null) {
        expect(fromFull, isNull, reason: c['name'] as String);
        expect(fromPayload, isNull, reason: c['name'] as String);
        continue;
      }
      final wanted = BlueLineAdvertisement(model: e['model'] as int, chipIdLow: e['chipIdLow'] as int);
      expect(fromFull, wanted);
      expect(fromPayload, wanted);
    }
  });
}
