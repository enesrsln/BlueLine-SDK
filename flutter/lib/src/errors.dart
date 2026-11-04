import 'protocol.dart';

/// Base class of every error thrown by the BlueLine SDK.
sealed class BlueLineException implements Exception {
  const BlueLineException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Bluetooth is off, missing, or the app has no permission.
final class BluetoothUnavailable extends BlueLineException {
  const BluetoothUnavailable(super.message);
}

/// Could not connect, or a GATT operation failed.
final class ConnectionFailed extends BlueLineException {
  const ConnectionFailed(super.message);
}

/// The device does not speak BlueLine protocol v1 (firmware older than 0.3.0),
/// or lacks the feature a command needs.
final class UnsupportedDevice extends BlueLineException {
  const UnsupportedDevice(super.message);
}

/// The device did not answer in time.
final class BlueLineTimeout extends BlueLineException {
  const BlueLineTimeout(super.message);
}

/// A command was called while not connected.
final class NotConnected extends BlueLineException {
  const NotConnected([super.message = 'not connected']);
}

/// The connection dropped while a request was pending, or the link was lost.
final class Disconnected extends BlueLineException {
  const Disconnected([super.message = 'disconnected']);
}

/// A bad argument, for example gain 5.
final class InvalidParameter extends BlueLineException {
  const InvalidParameter(super.message);
}

/// The device answered a control request with an error result.
final class CommandFailed extends BlueLineException {
  CommandFailed(this.command, this.rawResult)
      : super('${command.name} failed: ${BlueLineResult.fromCode(rawResult)?.name ?? 'result $rawResult'}');

  final BlueLineCommand command;
  final int rawResult;

  /// The result code, or null if this SDK does not know it.
  BlueLineResult? get result => BlueLineResult.fromCode(rawResult);
}
