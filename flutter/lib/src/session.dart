import 'protocol.dart';

/// Turns raw Signal notifications into packets of the active session.
///
/// Drops packets of other sessions, marks a gap when the sample index does not
/// continue, and attaches the session's microvolt scale. `BlueLineDevice` uses
/// one internally; it is public so recorded notifications can be replayed
/// through the same logic.
final class SignalSessionTracker {
  SignalSessionTracker(this.channelCount);

  final int channelCount;
  int? _session;
  double _scale = 0;
  int? _nextIndex;
  bool _pendingGap = false;

  /// Session of the running acquisition; null while the signal is stopped.
  int? get activeSession => _session;

  /// Starts accepting packets of [session]; sample indices restart.
  void begin(int session, double microvoltsPerCount) {
    _session = session;
    _scale = microvoltsPerCount;
    _nextIndex = null;
    _pendingGap = false;
  }

  /// Stops accepting packets.
  void end() {
    _session = null;
    _nextIndex = null;
    _pendingGap = false;
  }

  /// The next accepted packet gets `gapBefore = true` (for packets the app could not take).
  void markGap() {
    if (_session != null) _pendingGap = true;
  }

  /// Returns the packet if it belongs to the active session, else null.
  BlueLineSignalPacket? accept(List<int>? data) {
    final session = _session;
    if (session == null) return null;
    final packet = BlueLineSignalPacket.parse(data, channelCount);
    if (packet == null || packet.session != session) return null;
    final expected = _nextIndex;
    final gap = packet.gapBefore || _pendingGap || (expected != null && expected != packet.firstIndex);
    _pendingGap = false;
    _nextIndex = packet.nextIndex;
    return packet.copyWith(gapBefore: gap, microvoltsPerCount: _scale);
  }
}
