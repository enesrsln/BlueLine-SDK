import 'dart:async';

import 'package:universal_ble/universal_ble.dart';

import 'device.dart';
import 'errors.dart';
import 'protocol.dart';
import 'universal_ble_transport.dart';

/// A BlueLine device seen while scanning.
final class BlueLineDiscovery {
  const BlueLineDiscovery({required this.id, required this.name, required this.rssi, this.advertisement});

  /// Platform id: MAC address (Android, Windows, Linux) or a UUID (iOS, macOS).
  final String id;
  final String name;
  final int rssi;

  /// Model and chip id from the scan response, when present.
  final BlueLineAdvertisement? advertisement;

  @override
  String toString() => 'BlueLineDiscovery($name, $id, $rssi dBm)';
}

/// Bluetooth state, as needed for scanning and connecting.
enum BlueLineBluetoothState { unknown, unsupported, unauthorized, poweredOff, poweredOn }

/// Entry point: Bluetooth state, scanning and connecting.
abstract final class BlueLine {
  /// Asks for the Bluetooth permissions (Android 12+: scan and connect; iOS: the
  /// system prompt). Call before scanning. Windows and Linux need none.
  static Future<void> requestPermissions() async {
    try {
      await UniversalBle.requestPermissions();
    } catch (e) {
      throw BluetoothUnavailable('permission: $e');
    }
  }

  static Future<BlueLineBluetoothState> get bluetoothState async =>
      _state(await UniversalBle.getBluetoothAvailabilityState());

  static Stream<BlueLineBluetoothState> get bluetoothStateChanges => UniversalBle.availabilityStream.map(_state);

  static BlueLineBluetoothState _state(AvailabilityState s) => switch (s) {
        AvailabilityState.poweredOn => BlueLineBluetoothState.poweredOn,
        AvailabilityState.poweredOff => BlueLineBluetoothState.poweredOff,
        AvailabilityState.unauthorized => BlueLineBluetoothState.unauthorized,
        AvailabilityState.unsupported => BlueLineBluetoothState.unsupported,
        _ => BlueLineBluetoothState.unknown,
      };

  /// Scans while the stream is listened to, and stops after [timeout] if given.
  ///
  /// Each device is reported once, or on every advertisement with
  /// [allowDuplicates] (live RSSI). Cancelling the subscription stops scanning.
  static Stream<BlueLineDiscovery> scan({Duration? timeout, bool allowDuplicates = false}) {
    late final StreamController<BlueLineDiscovery> controller;
    StreamSubscription<BleDevice>? results;
    Timer? timer;
    final seen = <String>{};

    Future<void> stop() async {
      timer?.cancel();
      await results?.cancel();
      results = null;
      try {
        await UniversalBle.stopScan();
      } catch (_) {}
    }

    controller = StreamController<BlueLineDiscovery>(
      onListen: () async {
        results = UniversalBle.scanStream.listen((device) {
          final found = _asDiscovery(device);
          if (found == null || (!allowDuplicates && !seen.add(found.id))) return;
          controller.add(found);
        });
        try {
          // No service filter: the service UUID is in the scan response, which some
          // platform filters miss. Filtering happens on each result instead.
          // BlueLine uses legacy advertising; low latency is an active scan, which
          // requests the scan response (service UUID and manufacturer data).
          await UniversalBle.startScan(
            platformConfig: PlatformConfig(
              android: AndroidOptions(legacy: true, scanMode: AndroidScanMode.lowLatency),
            ),
          );
        } catch (e) {
          await stop();
          controller.addError(BluetoothUnavailable('scan: $e'));
          await controller.close();
          return;
        }
        if (timeout != null) {
          timer = Timer(timeout, () async {
            await stop();
            await controller.close();
          });
        }
      },
      onCancel: stop,
    );
    return controller.stream;
  }

  /// Scans for [timeout] and returns every BlueLine found, strongest signal first.
  static Future<List<BlueLineDiscovery>> discover({Duration timeout = const Duration(seconds: 5)}) async {
    final found = await scan(timeout: timeout).toList();
    return found..sort((a, b) => b.rssi.compareTo(a.rssi));
  }

  /// The first BlueLine seen (or the one with [id]), or null after [timeout].
  static Future<BlueLineDiscovery?> find({String? id, Duration timeout = const Duration(seconds: 10)}) async {
    await for (final d in scan(timeout: timeout)) {
      if (id == null || d.id.toLowerCase() == id.toLowerCase()) return d;
    }
    return null;
  }

  /// Connects, reads Info and the device information, and enables notifications.
  /// The device is then ready for `startSignal()`.
  static Future<BlueLineDevice> connect(BlueLineDiscovery discovery,
          {Duration timeout = const Duration(seconds: 20)}) =>
      connectToId(discovery.id, name: discovery.name, timeout: timeout);

  /// Connects by platform id, for example a MAC address saved from an earlier scan.
  static Future<BlueLineDevice> connectToId(String id,
          {String name = 'BlueLine', Duration timeout = const Duration(seconds: 20)}) =>
      BlueLineDevice.connectWith(UniversalBleTransport(id), id: id, name: name, timeout: timeout);

  static BlueLineDiscovery? _asDiscovery(BleDevice device) {
    BlueLineAdvertisement? advertisement;
    for (final m in device.manufacturerDataList) {
      if (m.companyId == BlueLineV1.companyId) advertisement ??= BlueLineAdvertisement.fromCompanyPayload(m.payload);
    }
    final hasService = device.services.any((s) => s.toLowerCase() == BlueLineV1.serviceUuid);
    if (!hasService && advertisement == null) return null;
    final name = device.name;
    return BlueLineDiscovery(
      id: device.deviceId,
      name: name == null || name.isEmpty ? 'BlueLine' : name,
      rssi: device.rssi ?? 0,
      advertisement: advertisement,
    );
  }
}
