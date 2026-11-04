import 'dart:async';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'errors.dart';
import 'transport.dart';

/// [BlueLineTransport] on [universal_ble](https://pub.dev/packages/universal_ble)
/// (BSD-3): Android, iOS, macOS, Windows and Linux.
final class UniversalBleTransport implements BlueLineTransport {
  UniversalBleTransport(this.deviceId);

  final String deviceId;
  final _linkLost = Completer<void>();
  final _subscriptions = <StreamSubscription<Object?>>[];
  StreamSubscription<bool>? _connection;

  @override
  Future<void> get linkLost => _linkLost.future;

  @override
  Future<void> connect(Duration timeout) async {
    try {
      await UniversalBle.connect(deviceId, timeout: timeout);
    } on TimeoutException {
      throw const BlueLineTimeout('connect');
    } catch (e) {
      throw ConnectionFailed('connect: $e');
    }
    _connection = UniversalBle.connectionStream(deviceId).listen((connected) {
      if (!connected) _lost();
    });
  }

  void _lost() {
    if (!_linkLost.isCompleted) _linkLost.complete();
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
    _connection?.cancel();
    _connection = null;
  }

  @override
  Future<void> disconnect() async {
    try {
      await UniversalBle.disconnect(deviceId, timeout: const Duration(seconds: 5));
    } catch (_) {
      // Already disconnected, or the stack gave up: the link is gone either way.
    }
    _lost();
  }

  @override
  Future<Set<String>> discoverCharacteristics() async {
    final services = await _guard('discovering services', () => UniversalBle.discoverServices(deviceId));
    return {
      for (final s in services)
        for (final c in s.characteristics) c.uuid.toLowerCase(),
    };
  }

  @override
  Future<Uint8List> read(String service, String characteristic) =>
      _guard('reading $characteristic', () => UniversalBle.read(deviceId, service, characteristic));

  @override
  Future<void> write(String service, String characteristic, Uint8List value) =>
      _guard('writing $characteristic', () => UniversalBle.write(deviceId, service, characteristic, value));

  @override
  Future<void> subscribe(String service, String characteristic, void Function(Uint8List value) onValue) async {
    // Listen first so no notification sent right after enabling is missed.
    _subscriptions.add(UniversalBle.characteristicValueStream(deviceId, characteristic).listen(onValue));
    await _guard('enabling notifications on $characteristic',
        () => UniversalBle.subscribeNotifications(deviceId, service, characteristic));
  }

  @override
  Future<int?> requestMtu(int mtu) async {
    try {
      return await UniversalBle.requestMtu(deviceId, mtu);
    } catch (_) {
      return null; // not supported on this platform; the stack negotiates by itself
    }
  }

  @override
  Future<void> optimizeForStreaming() async {
    try {
      // Android only; other platforms choose the connection interval themselves.
      await UniversalBle.requestConnectionPriority(deviceId, BleConnectionPriority.highPerformance);
    } catch (_) {}
  }

  static Future<T> _guard<T>(String what, Future<T> Function() op) async {
    try {
      return await op();
    } on BlueLineException {
      rethrow;
    } on TimeoutException {
      throw BlueLineTimeout(what);
    } catch (e) {
      throw ConnectionFailed('$what: $e');
    }
  }
}
