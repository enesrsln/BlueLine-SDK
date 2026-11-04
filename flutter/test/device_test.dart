// BlueLineDevice against a fake transport that behaves like the firmware
// (same cases as the Python test_device.py).
import 'dart:async';
import 'dart:typed_data';

import 'package:blueline_sdk/blueline_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

const infoHex = '0104010400030118E803FA000406A0252600640013081B00EFCDAB8967452301'; // protocol 1, gain 6, 4 ch

Uint8List hex(String s) =>
    Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

Uint8List le16(int v) => Uint8List.fromList([v & 0xFF, (v >> 8) & 0xFF]);
Uint8List le32(int v) => Uint8List.fromList([for (var i = 0; i < 4; i++) (v >> (8 * i)) & 0xFF]);

Uint8List signalBytes(int session, int firstIndex, {int count = 5, int channels = 4}) => Uint8List.fromList([
      0, count, ...le16(session), ...le32(firstIndex),
      for (var i = 0; i < count * channels; i++) ...[0, 0, 1],
    ]);

Uint8List statusBytes({bool streaming = false, int gain = 6, int session = 0}) => Uint8List.fromList([
      streaming ? 1 : 0, 0, 80, gain, ...le16(247), ...le16(session), ...le32(0), ...le32(0), ...le32(0),
    ]);

/// Firmware behaviour behind the transport.
class FakeFirmware implements BlueLineTransport {
  Uint8List info = hex(infoHex);
  int session = 0;
  int gain = 6;
  bool streaming = false;
  bool answer = true;
  bool busy = false;
  final writes = <List<int>>[];
  final handlers = <String, void Function(Uint8List)>{};
  int signalAfterStart = 0;
  bool connected = false;
  Completer<void> _linkLost = Completer();

  @override
  Future<void> get linkLost => _linkLost.future;

  @override
  Future<void> connect(Duration timeout) async => connected = true;

  @override
  Future<void> disconnect() async {
    if (!connected) return;
    connected = false;
    if (!_linkLost.isCompleted) _linkLost.complete();
  }

  @override
  Future<Set<String>> discoverCharacteristics() async => {
        BlueLineV1.infoUuid, BlueLineV1.signalUuid, BlueLineV1.memsUuid, BlueLineV1.statusUuid,
        BlueLineV1.controlUuid, BlueLineV1.serialNumberUuid, BlueLineV1.firmwareRevisionUuid,
        BlueLineV1.batteryLevelUuid,
      };

  @override
  Future<Uint8List> read(String service, String characteristic) async => switch (characteristic) {
        BlueLineV1.infoUuid => info,
        BlueLineV1.statusUuid => statusBytes(streaming: streaming, gain: gain, session: session),
        BlueLineV1.serialNumberUuid => Uint8List.fromList('BL4-000042'.codeUnits),
        BlueLineV1.firmwareRevisionUuid => Uint8List.fromList('0.3.1'.codeUnits),
        BlueLineV1.batteryLevelUuid => Uint8List.fromList([0x57]),
        _ => throw ConnectionFailed('no $characteristic'),
      };

  @override
  Future<void> subscribe(String service, String characteristic, void Function(Uint8List) onValue) async =>
      handlers[characteristic] = onValue;

  @override
  Future<int?> requestMtu(int mtu) async => 247;

  @override
  Future<void> optimizeForStreaming() async {}

  void notify(String uuid, List<int> data) => handlers[uuid]!(Uint8List.fromList(data));

  void later(String uuid, List<int> data) => scheduleMicrotask(() => notify(uuid, data));

  @override
  Future<void> write(String service, String characteristic, Uint8List data) async {
    expect(characteristic, BlueLineV1.controlUuid);
    writes.add(data.toList());
    if (!answer) return;
    final op = data[0];
    if (busy) return later(BlueLineV1.controlUuid, [0xFF, BlueLineResult.busy.code]);
    var payload = <int>[];
    if (op == BlueLineCommand.startSignal.opcode) {
      if (!streaming) {
        session++;
        streaming = true;
      }
      payload = le16(session);
    } else if (op == BlueLineCommand.stopSignal.opcode) {
      streaming = false;
    } else if (op == BlueLineCommand.setGain.opcode) {
      gain = data[1];
      if (streaming) session++;
      payload = [gain, ...le16(session)];
    } else if (op == BlueLineCommand.identify.opcode && identifyNotSupported) {
      return later(BlueLineV1.controlUuid, [op, BlueLineResult.notSupported.code]);
    }
    later(BlueLineV1.controlUuid, [op, BlueLineResult.ok.code, ...payload]);
    if (op == BlueLineCommand.startSignal.opcode) {
      for (var i = 0; i < signalAfterStart; i++) {
        later(BlueLineV1.signalUuid, signalBytes(session, 5 * i));
      }
    }
  }

  bool identifyNotSupported = false;

  void sendSignal(int firstIndex, {int? session, int count = 5}) =>
      notify(BlueLineV1.signalUuid, signalBytes(session ?? this.session, firstIndex, count: count));

  void dropLink() {
    connected = false;
    _linkLost.complete();
    _linkLost = Completer();
  }
}

void main() {
  late FakeFirmware fw;

  setUp(() => fw = FakeFirmware());

  Future<BlueLineDevice> connect({Duration commandTimeout = const Duration(seconds: 3)}) =>
      BlueLineDevice.connectWith(fw, id: 'AA:BB:CC:DD:EE:FF', name: 'BlueLine-4', commandTimeout: commandTimeout);

  test('connect reads the device description', () async {
    final dev = await connect();
    expect(dev.isConnected, isTrue);
    expect(dev.info.channelCount, 4);
    expect(dev.info.firmwareVersion, '0.3.1');
    expect(dev.serialNumber, 'BL4-000042');
    expect(dev.firmwareRevision, '0.3.1');
    expect(dev.batteryLevel, 0x57);
    expect(dev.mtu, 247);
    expect(dev.status!.isStreaming, isFalse);
    expect(fw.handlers.keys.toSet(), {
      BlueLineV1.controlUuid, BlueLineV1.statusUuid, BlueLineV1.signalUuid, BlueLineV1.memsUuid,
      BlueLineV1.batteryLevelUuid,
    });
  });

  test('old firmware is rejected and the link closed', () async {
    fw.info = Uint8List.fromList([2, ...fw.info.sublist(1)]);
    await expectLater(connect(), throwsA(isA<UnsupportedDevice>()));
    expect(fw.connected, isFalse);
  });

  test('signal of the current session only, with its scale', () async {
    final dev = await connect();
    final received = <BlueLineSignalPacket>[];
    dev.signal.listen(received.add);
    fw.sendSignal(0, session: 1); // before start: dropped
    expect(await dev.startSignal(), 1);
    fw.sendSignal(0);
    fw.sendSignal(5, session: 99); // other session: dropped
    fw.sendSignal(5);
    expect(received.map((p) => p.firstIndex), [0, 5]);
    expect(received[0].microvoltsPerCount, closeTo(dev.info.microvoltsPerCount, 1e-15));
    expect(received[0].microvolts[0][0], closeTo(dev.info.microvoltsPerCount, 1e-15));
  });

  test('first packets after start are not lost', () async {
    fw.signalAfterStart = 2;
    final dev = await connect();
    final received = <BlueLineSignalPacket>[];
    dev.signal.listen(received.add);
    await dev.startSignal();
    await Future<void>.delayed(Duration.zero);
    expect(received.map((p) => p.firstIndex), [0, 5]);
  });

  test('gap is marked', () async {
    final dev = await connect();
    final received = <BlueLineSignalPacket>[];
    dev.signal.listen(received.add);
    await dev.startSignal();
    for (final first in [0, 5, 15]) {
      fw.sendSignal(first);
    }
    expect(received.map((p) => p.gapBefore), [false, false, true]);
  });

  test('setGain starts a new session and rescales', () async {
    final dev = await connect();
    final received = <BlueLineSignalPacket>[];
    dev.signal.listen(received.add);
    final first = await dev.startSignal();
    final scale6 = dev.info.microvoltsPerCount;
    final second = await dev.setGain(12);
    expect(second, first + 1);
    expect(dev.session, second);
    expect(dev.info.gain, 12);
    fw.sendSignal(100, session: first); // old session: dropped
    fw.sendSignal(0);
    expect(received, hasLength(1));
    expect(received[0].microvoltsPerCount, closeTo(scale6 / 2, 1e-15));
  });

  test('setGain validates locally', () async {
    final dev = await connect();
    await expectLater(dev.setGain(5), throwsA(isA<InvalidParameter>()));
    expect(fw.writes, isEmpty);
  });

  test('busy and not supported', () async {
    final dev = await connect();
    fw.identifyNotSupported = true;
    await expectLater(
        dev.identify(), throwsA(isA<CommandFailed>().having((e) => e.result, 'result', BlueLineResult.notSupported)));
    fw.busy = true;
    await expectLater(
        dev.startSignal(), throwsA(isA<CommandFailed>().having((e) => e.result, 'result', BlueLineResult.busy)));
  });

  test('timeout', () async {
    final dev = await connect(commandTimeout: const Duration(milliseconds: 50));
    fw.answer = false;
    await expectLater(dev.identify(), throwsA(isA<BlueLineTimeout>()));
    fw.answer = true;
    await dev.identify(); // the next command still works
  });

  test('commands run one at a time, in call order', () async {
    final dev = await connect();
    await Future.wait([dev.startSignal(), dev.startMems(), dev.identify()]);
    expect(fw.writes.map((w) => w[0]), [
      BlueLineCommand.startSignal.opcode, BlueLineCommand.startMems.opcode, BlueLineCommand.identify.opcode,
    ]);
  });

  test('a failed command does not block the next one', () async {
    final dev = await connect();
    fw.busy = true;
    final failing = dev.startSignal();
    final next = dev.identify(); // queued behind the failing command
    await expectLater(failing, throwsA(isA<CommandFailed>()));
    await expectLater(next, throwsA(isA<CommandFailed>())); // still busy, but it ran
    fw.busy = false;
    expect(await dev.startSignal(), 1);
    expect(fw.writes, hasLength(3));
  });

  test('disconnect stops the signal first and reports null', () async {
    final dev = await connect();
    await dev.startSignal();
    await dev.disconnect();
    expect(fw.writes.last, [BlueLineCommand.stopSignal.opcode]);
    expect(dev.isConnected, isFalse);
    expect(fw.connected, isFalse);
    expect(await dev.done, isNull);
    await expectLater(dev.startSignal(), throwsA(isA<NotConnected>()));
  });

  test('link loss fails the pending command, reports, and closes the streams', () async {
    final dev = await connect();
    final signalDone = dev.signal.toList();
    fw.answer = false;
    final pending = dev.identify();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    fw.dropLink();
    await expectLater(pending, throwsA(isA<Disconnected>()));
    expect(await dev.done, isA<Disconnected>());
    expect(dev.isConnected, isFalse);
    expect(await signalDone, isEmpty);
  });

  test('mems of the active session', () async {
    final dev = await connect();
    final got = <BlueLineMemsSample>[];
    dev.mems.listen(got.add);
    List<int> mems(int session) => [...le16(session), ...le32(1), ...le32(0xFFFFFFFF), 0, 0, 0, 0, 0, 1];
    fw.notify(BlueLineV1.memsUuid, mems(7)); // signal stopped: any session passes
    await dev.startSignal();
    fw.notify(BlueLineV1.memsUuid, mems(99)); // other session: dropped
    fw.notify(BlueLineV1.memsUuid, mems(1));
    expect(got.map((m) => m.session), [7, 1]);
    expect(got[0].signalIndex, isNull);
  });
}
