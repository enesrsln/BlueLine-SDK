"""Session and lost-sample tracking for Signal notifications."""

from __future__ import annotations

from dataclasses import replace
from typing import Optional

from .protocol import SignalPacket


class SignalSessionTracker:
    """Turns raw Signal notifications into packets of the active session.

    Drops packets of other sessions, marks a gap when the sample index does not
    continue, and attaches the session's microvolt scale. ``BlueLineDevice`` uses
    one internally; it is public so recorded notifications can be replayed
    through the same logic.
    """

    def __init__(self, channel_count: int):
        self._channel_count = channel_count
        self._session: Optional[int] = None
        self._scale = 0.0
        self._next_index: Optional[int] = None
        self._pending_gap = False

    @property
    def active_session(self) -> Optional[int]:
        """Session of the running acquisition; None while the signal is stopped."""
        return self._session

    def begin(self, session: int, microvolts_per_count: float) -> None:
        """Starts accepting packets of ``session``; sample indices restart."""
        self._session = session
        self._scale = microvolts_per_count
        self._next_index = None
        self._pending_gap = False

    def end(self) -> None:
        """Stops accepting packets."""
        self._session = None
        self._next_index = None
        self._pending_gap = False

    def mark_gap(self) -> None:
        """The next accepted packet gets ``gap_before=True``."""
        if self._session is not None:
            self._pending_gap = True

    def accept(self, data: Optional[bytes]) -> Optional[SignalPacket]:
        """Returns the packet if it belongs to the active session, else None."""
        if self._session is None:
            return None
        packet = SignalPacket.parse(data, self._channel_count)
        if packet is None or packet.session != self._session:
            return None
        expected = self._next_index
        gap = packet.gap_before or self._pending_gap or (expected is not None and expected != packet.first_index)
        self._pending_gap = False
        self._next_index = packet.next_index
        return replace(packet, gap_before=gap, microvolts_per_count=self._scale)
