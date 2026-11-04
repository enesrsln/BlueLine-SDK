// BlueLine SDK example: scan, connect, stream EEG, show band powers.
import 'dart:async';

import 'package:blueline_sdk/blueline_sdk.dart';
import 'package:flutter/material.dart';

void main() => runApp(const MaterialApp(title: 'BlueLine', home: ScanPage()));

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _found = <String, BlueLineDiscovery>{};
  StreamSubscription<BlueLineDiscovery>? _scan;
  String? _error;
  bool _connecting = false;

  Future<void> _startScan() async {
    setState(() {
      _found.clear();
      _error = null;
    });
    try {
      await BlueLine.requestPermissions();
    } on BlueLineException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    await _scan?.cancel();
    _scan = BlueLine.scan(timeout: const Duration(seconds: 10)).listen(
      (d) => setState(() => _found[d.id] = d),
      onError: (Object e) => setState(() => _error = '$e'),
      onDone: () {
        if (mounted) setState(() => _scan = null);
      },
    );
    setState(() {});
  }

  Future<void> _connect(BlueLineDiscovery d) async {
    await _scan?.cancel();
    setState(() {
      _scan = null;
      _connecting = true;
    });
    try {
      final device = await BlueLine.connect(d);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DevicePage(device: device)));
    } on BlueLineException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  void dispose() {
    _scan?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final devices = _found.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
    return Scaffold(
      appBar: AppBar(title: const Text('BlueLine devices')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _scan == null && !_connecting ? _startScan : null,
        icon: const Icon(Icons.bluetooth_searching),
        label: Text(_scan == null ? 'Scan' : 'Scanning...'),
      ),
      body: Column(children: [
        if (_connecting) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        Expanded(
          child: ListView(children: [
            for (final d in devices)
              ListTile(
                leading: const Icon(Icons.sensors),
                title: Text(d.name),
                subtitle: Text('${d.id}   ${d.rssi} dBm'),
                onTap: _connecting ? null : () => _connect(d),
              ),
          ]),
        ),
      ]),
    );
  }
}

class DevicePage extends StatefulWidget {
  const DevicePage({super.key, required this.device});

  final BlueLineDevice device;

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  BlueLineDevice get device => widget.device;
  late final SignalFilter _filter;
  late final SpectrumAnalyzer _analyzer;
  final _subs = <StreamSubscription<Object?>>[];
  Timer? _rateTimer;

  bool _streaming = false;
  int _samples = 0;
  int _samplesPerSecond = 0;
  int _gaps = 0;
  List<double> _latest = const [];
  SpectrumFrame? _frame;
  BlueLineMemsSample? _mems;
  String? _message;

  @override
  void initState() {
    super.initState();
    final info = device.info;
    final rate = info.signalRateHz.toDouble();
    _filter = SignalFilter(info.channelCount, sampleRate: rate);
    _analyzer = SpectrumAnalyzer(info.channelCount, sampleRate: rate, updateRate: 2);
    _subs
      ..add(device.signal.listen(_onSignal))
      ..add(device.mems.listen((m) => _mems = m))
      ..add(device.statusUpdates.listen((_) => setState(() {})));
    _rateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {
        _samplesPerSecond = _samples;
        _samples = 0;
      });
    });
    device.done.then((error) {
      if (!mounted) return;
      setState(() {
        _streaming = false;
        _message = error == null ? 'Disconnected' : 'Connection lost: ${error.message}';
      });
    });
  }

  void _onSignal(BlueLineSignalPacket packet) {
    if (packet.gapBefore) _gaps++;
    _samples += packet.sampleCount;
    final filtered = _filter.process(packet);
    if (filtered.isNotEmpty) _latest = filtered.last;
    final frames = _analyzer.process(packet);
    if (frames.isNotEmpty) setState(() => _frame = frames.last);
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) setState(() => _message = null);
    } on BlueLineException catch (e) {
      if (mounted) setState(() => _message = e.message);
    }
  }

  Future<void> _toggle() => _run(() async {
        final mems = device.info.supports(BlueLineFeature.mems);
        if (_streaming) {
          await device.stopSignal();
          if (mems) await device.stopMems();
        } else {
          await device.startSignal();
          if (mems) await device.startMems();
        }
        _streaming = !_streaming;
      });

  @override
  void dispose() {
    _rateTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    device.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = device.info;
    final text = Theme.of(context).textTheme;
    final battery = device.status?.batteryPercent ?? device.batteryLevel;
    final serial = device.serialNumber ?? '-';
    return Scaffold(
      appBar: AppBar(title: Text(device.name)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Serial $serial · firmware ${info.firmwareVersion} · '
            '${info.channelCount} ch at ${info.signalRateHz} Hz · battery ${battery ?? '?'}%'),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilledButton.icon(
            onPressed: device.isConnected ? _toggle : null,
            icon: Icon(_streaming ? Icons.stop : Icons.play_arrow),
            label: Text(_streaming ? 'Stop' : 'Start'),
          ),
          OutlinedButton(
            onPressed: device.isConnected ? () => _run(device.identify) : null,
            child: const Text('Identify'),
          ),
          DropdownButton<int>(
            value: info.gain,
            items: [for (final g in BlueLineV1.supportedGains) DropdownMenuItem(value: g, child: Text('Gain $g'))],
            onChanged: device.isConnected ? (g) => _run(() => device.setGain(g!)) : null,
          ),
        ]),
        if (_message != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_message!)),
        const SizedBox(height: 16),
        Text('Signal', style: text.titleMedium),
        Text('$_samplesPerSecond samples/s · gaps $_gaps · session ${device.session ?? '-'}'),
        if (_latest.isNotEmpty) Text('Filtered µV: ${_latest.map((v) => v.toStringAsFixed(1)).join('   ')}'),
        if (_mems != null)
          Text('Accelerometer g: ${_mems!.xG.toStringAsFixed(2)}  '
              '${_mems!.yG.toStringAsFixed(2)}  ${_mems!.zG.toStringAsFixed(2)}'),
        const SizedBox(height: 16),
        Text('Band powers (share of total)', style: text.titleMedium),
        if (_frame == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(value: _streaming ? _analyzer.fill : 0),
          )
        else
          for (var c = 0; c < _frame!.channels.length; c++) _BandBars(channel: c + 1, spectrum: _frame!.channels[c]),
      ]),
    );
  }
}

class _BandBars extends StatelessWidget {
  const _BandBars({required this.channel, required this.spectrum});

  final int channel;
  final ChannelSpectrum spectrum;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        SizedBox(width: 40, child: Text('CH$channel')),
        for (final band in EegBand.defaults)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Column(children: [
                LinearProgressIndicator(value: spectrum.relative[band.name] ?? 0, minHeight: 8),
                Text('${band.name} ${(100 * (spectrum.relative[band.name] ?? 0)).toStringAsFixed(0)}%',
                    style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
          ),
      ]),
    );
  }
}
