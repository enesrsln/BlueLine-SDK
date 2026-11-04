import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';
import 'protocol.dart';
import 'session.dart';
import 'transport.dart';

/// A connected BlueLine device, from `BlueLine.connect`.
///
/// Commands return futures and run one at a time (the firmware rejects
/// overlapping requests); failures throw [BlueLineException] subclasses. Data
/// arrives on broadcast streams: [signal], [mems], [statusUpdates] and
/// [batteryLevels]. [done] completes when the connection closes.
final class BlueLineDevice {
  BlueLineDevice._(this.id, this.name, this._transport, this.commandTimeout);

  /// Connects through [transport] and prepares the device: reads Info and the
  /// device information, enables notifications. `BlueLine.connect` calls this with
  /// a `UniversalBleTransport`; call it directly to use another Bluetooth stack.
  static Future<BlueLineDevice> connectWith(
    BlueLineTransport transport, {
    required String id,
    String name = 'BlueLine',
    Duration timeout = const Duration(seconds: 20),
    Duration commandTimeout = const Duration(seconds: 3),
  }) async {
    final device = BlueLineDevice._(id, name, transport, commandTimeout);
    try {
      await device._establish(timeout).timeout(timeout);
    } on TimeoutException {
      await device._abort();
      throw const BlueLineTimeout('connect');
    } catch (_) {
      await device._abort();
      rethrow;
    }
    return device;
  }

  /// Platform id: MAC address (Android, Windows, Linux) or a UUID (iOS, macOS).
  final String id;
  final String name;
  final BlueLineTransport _transport;

  /// How long a command waits for the device's answer.
  final Duration commandTimeout;

  BlueLineInfo? _info;
  SignalSessionTracker? _tracker;
  bool _connected = false;
  bool _userDisconnect = false;
  Future<void> _commandChain = Future.value();
  _Pending? _pending;
  final _done = Completer<BlueLineException?>();

  final _signal = StreamController<BlueLineSignalPacket>.broadcast(sync: true);
  final _mems = StreamController<BlueLineMemsSample>.broadcast(sync: true);
  final _status = StreamController<BlueLineStatus>.broadcast(sync: true);
  final _battery = StreamController<int>.broadcast(sync: true);

  String? _serialNumber;
  String? _firmwareRevision;
  int? _batteryLevel;
  BlueLineStatus? _lastStatus;
  int? _mtu;

  // ------------------------------------------------------------------ properties

  /// Read during connection; `gain` follows [setGain].
  BlueLineInfo get info => _info ?? (throw const NotConnected());

  String? get serialNumber => _serialNumber;
  String? get firmwareRevision => _firmwareRevision;
  int? get batteryLevel => _batteryLevel;
  BlueLineStatus? get status => _lastStatus;

  /// Negotiated ATT MTU, if the platform reports it.
  int? get mtu => _mtu;

  bool get isConnected => _connected;

  /// Session of the running acquisition; null while the signal is stopped.
  int? get session => _tracker?.activeSession;

  /// EEG packets of the current session (about every 20 ms, 5 samples at 250 Hz).
  Stream<BlueLineSignalPacket> get signal => _signal.stream;

  /// Accelerometer samples (100 Hz) after [startMems].
  Stream<BlueLineMemsSample> get mems => _mems.stream;

  /// State, gain and loss counters.
  Stream<BlueLineStatus> get statusUpdates => _status.stream;

  Stream<int> get batteryLevels => _battery.stream;

  /// Completes when the connection closes: with null after [disconnect], or with
  /// [Disconnected] when the link was lost.
  Future<BlueLineException?> get done => _done.future;

  // ------------------------------------------------------------------ commands

  /// Starts EEG acquisition and returns the session. If already streaming the
  /// device keeps the current session and returns it. Sample indices restart at 0.
  Future<int> startSignal() async {
    final r = await _send(BlueLineCommand.startSignal);
    return r.session ?? (throw CommandFailed(BlueLineCommand.startSignal, r.rawResult));
  }

  Future<void> stopSignal() => _send(BlueLineCommand.stopSignal);

  /// Starts the accelerometer stream ([mems]).
  Future<void> startMems() {
    _require(BlueLineFeature.mems);
    return _send(BlueLineCommand.startMems);
  }

  Future<void> stopMems() => _send(BlueLineCommand.stopMems);

  /// Sets the PGA gain (1, 2, 4, 6, 8, 12 or 24; 6 after every boot).
  ///
  /// While streaming this restarts acquisition: a new session starts and the
  /// sample index restarts at 0. Never mix samples of different sessions.
  /// Returns the session.
  Future<int> setGain(int gain) async {
    if (!BlueLineV1.supportedGains.contains(gain)) {
      throw InvalidParameter('gain $gain not in ${BlueLineV1.supportedGains}');
    }
    _require(BlueLineFeature.setGain);
    final r = await _send(BlueLineCommand.setGain, [gain]);
    return r.session ?? (throw CommandFailed(BlueLineCommand.setGain, r.rawResult));
  }

  /// Blinks the device LED green for 2 seconds.
  Future<void> identify() {
    _require(BlueLineFeature.identify);
    return _send(BlueLineCommand.identify);
  }

  /// Stops acquisition (STOP_SIGNAL) and closes the connection.
  Future<void> disconnect() async {
    if (!_connected) return;
    if (session != null) {
      try {
        await _send(BlueLineCommand.stopSignal, const [], const Duration(seconds: 1));
      } on BlueLineException {
        // Disconnecting stops acquisition on the device anyway.
      }
    }
    _userDisconnect = true;
    await _transport.disconnect();
    _handleDisconnect(null);
  }

  // ------------------------------------------------------------------ internals

  void _require(BlueLineFeature feature) {
    if (!info.supports(feature)) {
      throw UnsupportedDevice('feature ${feature.name} not supported by firmware ${info.firmwareVersion}');
    }
  }

  Future<BlueLineControlResponse> _send(BlueLineCommand command, [List<int> params = const [], Duration? timeout]) {
    // One request at a time: chain on the previous command, whatever its outcome.
    final result = _commandChain.then((_) => _sendNow(command, params, timeout ?? commandTimeout));
    _commandChain = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<BlueLineControlResponse> _sendNow(BlueLineCommand command, List<int> params, Duration timeout) async {
    if (!_connected) throw const NotConnected();
    final pending = _Pending(command);
    _pending = pending;
    try {
      await _transport.write(BlueLineV1.serviceUuid, BlueLineV1.controlUuid, command.request(params));
      final BlueLineControlResponse response;
      try {
        response = await pending.completer.future.timeout(timeout);
      } on TimeoutException {
        throw BlueLineTimeout(command.name);
      }
      if (!response.isOk) throw CommandFailed(command, response.rawResult);
      return response;
    } finally {
      if (identical(_pending, pending)) _pending = null;
    }
  }

  Future<void> _establish(Duration timeout) async {
    await _transport.connect(timeout);
    _connected = true;
    unawaited(_transport.linkLost.then((_) => _handleDisconnect(const Disconnected('link lost'))));

    final characteristics = await _transport.discoverCharacteristics();
    if (!characteristics.contains(BlueLineV1.infoUuid)) {
      throw const UnsupportedDevice('no BlueLine v1 service (firmware older than 0.3.0?)');
    }
    _mtu = await _transport.requestMtu(247);
    await _transport.optimizeForStreaming();

    final info = BlueLineInfo.parse(await _transport.read(BlueLineV1.serviceUuid, BlueLineV1.infoUuid));
    if (info == null) throw const UnsupportedDevice('unreadable Info');
    if (!info.isSupported) {
      throw UnsupportedDevice('protocol ${info.protocolVersion}, firmware ${info.firmwareVersion}');
    }
    _info = info;
    _tracker = SignalSessionTracker(info.channelCount);

    Future<String?> text(String uuid) async {
      if (!characteristics.contains(uuid)) return null;
      try {
        final bytes = await _transport.read(BlueLineV1.deviceInformationServiceUuid, uuid);
        return utf8.decode(bytes, allowMalformed: true).replaceAll('\u0000', '').trim();
      } on BlueLineException {
        return null;
      }
    }

    _serialNumber = await text(BlueLineV1.serialNumberUuid);
    _firmwareRevision = await text(BlueLineV1.firmwareRevisionUuid);

    const s = BlueLineV1.serviceUuid;
    await _transport.subscribe(s, BlueLineV1.controlUuid, _onControl);
    await _transport.subscribe(s, BlueLineV1.statusUuid, _onStatus);
    await _transport.subscribe(s, BlueLineV1.signalUuid, _onSignal);
    if (info.supports(BlueLineFeature.mems)) await _transport.subscribe(s, BlueLineV1.memsUuid, _onMems);
    _lastStatus = BlueLineStatus.parse(await _transport.read(s, BlueLineV1.statusUuid));

    if (characteristics.contains(BlueLineV1.batteryLevelUuid)) {
      try {
        final level = await _transport.read(BlueLineV1.batteryServiceUuid, BlueLineV1.batteryLevelUuid);
        if (level.isNotEmpty) _batteryLevel = level[0];
        await _transport.subscribe(BlueLineV1.batteryServiceUuid, BlueLineV1.batteryLevelUuid, _onBattery);
      } on BlueLineException {
        // Optional; Status also reports the battery.
      }
    }
  }

  Future<void> _abort() async {
    _userDisconnect = true;
    await _transport.disconnect();
    _handleDisconnect(null);
  }

  void _handleDisconnect(BlueLineException? error) {
    if (_done.isCompleted) return;
    final wasConnected = _connected;
    _connected = false;
    _tracker?.end();
    final pending = _pending;
    if (pending != null && !pending.completer.isCompleted) pending.completer.completeError(const Disconnected());
    _done.complete(wasConnected && !_userDisconnect ? error : null);
    _signal.close();
    _mems.close();
    _status.close();
    _battery.close();
  }

  // ------------------------------------------------------------------ notifications

  void _onSignal(Uint8List data) {
    final packet = _tracker?.accept(data);
    if (packet != null && !_signal.isClosed) _signal.add(packet);
  }

  void _onMems(Uint8List data) {
    final sample = BlueLineMemsSample.parse(data);
    if (sample == null || _mems.isClosed) return;
    final active = session;
    if (active == null || sample.session == active) _mems.add(sample);
  }

  void _onControl(Uint8List data) {
    final response = BlueLineControlResponse.parse(data);
    final pending = _pending;
    if (response == null || pending == null || !response.answers(pending.command)) return;
    _onControlResponse(pending.command, response);
    if (!pending.completer.isCompleted) pending.completer.complete(response);
  }

  /// Runs in the notification handler, before the caller resumes, so no packet of
  /// a new session is dropped in between.
  void _onControlResponse(BlueLineCommand command, BlueLineControlResponse response) {
    final tracker = _tracker;
    if (!response.isOk || tracker == null) return;
    switch (command) {
      case BlueLineCommand.startSignal:
        final s = response.session;
        if (s != null) tracker.begin(s, info.microvoltsPerCount);
      case BlueLineCommand.stopSignal:
        tracker.end();
      case BlueLineCommand.setGain:
        if (response.payload.isNotEmpty && response.payload[0] > 0) _info = info.withGain(response.payload[0]);
        final s = response.session;
        if (tracker.activeSession != null && s != null) tracker.begin(s, info.microvoltsPerCount);
      default:
        break;
    }
  }

  void _onStatus(Uint8List data) {
    final status = BlueLineStatus.parse(data);
    if (status == null) return;
    _lastStatus = status;
    if (!_status.isClosed) _status.add(status);
  }

  void _onBattery(Uint8List data) {
    if (data.isEmpty) return;
    _batteryLevel = data[0];
    if (!_battery.isClosed) _battery.add(data[0]);
  }

  @override
  String toString() => 'BlueLineDevice($name, $id)';
}

final class _Pending {
  _Pending(this.command);

  final BlueLineCommand command;
  final completer = Completer<BlueLineControlResponse>();
}
