/// BlueLine SDK for Flutter: stream EEG and accelerometer data from BlueLine
/// devices, with filters, spectrum and band powers.
///
/// ```dart
/// final found = await BlueLine.discover();
/// final device = await BlueLine.connect(found.first);
/// device.signal.listen((packet) => print(packet.microvolts.first));
/// await device.startSignal();
/// ```
library;

export 'blueline_core.dart';
export 'src/blueline.dart';
export 'src/device.dart';
export 'src/transport.dart';
export 'src/universal_ble_transport.dart';
