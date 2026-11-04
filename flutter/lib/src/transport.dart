import 'dart:async';
import 'dart:typed_data';

/// The GATT operations `BlueLineDevice` needs from a Bluetooth stack.
///
/// The SDK ships [UniversalBleTransport]. Implement this to use another
/// Bluetooth library, or to drive `BlueLineDevice` from tests.
/// UUIDs are lowercase 128-bit strings.
abstract interface class BlueLineTransport {
  /// Connects; throws on failure.
  Future<void> connect(Duration timeout);

  /// Disconnects; completes when the link is closed. Must not throw.
  Future<void> disconnect();

  /// Discovers services and returns every characteristic UUID found.
  Future<Set<String>> discoverCharacteristics();

  Future<Uint8List> read(String service, String characteristic);

  /// Write with response.
  Future<void> write(String service, String characteristic, Uint8List value);

  /// Enables notifications; [onValue] receives every notification afterwards.
  Future<void> subscribe(String service, String characteristic, void Function(Uint8List value) onValue);

  /// Requests a larger MTU and returns the negotiated one, or null if unknown.
  Future<int?> requestMtu(int mtu);

  /// Platform tuning for streaming (connection priority, PHY). Best effort, must not throw.
  Future<void> optimizeForStreaming();

  /// Completes when the link drops, for any reason.
  Future<void> get linkLost;
}
