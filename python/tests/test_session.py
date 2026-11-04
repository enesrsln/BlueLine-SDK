"""Session and gap tracking (same cases as the Android SignalSessionTrackerTest)."""

import struct
import unittest

from blueline import SignalSessionTracker


def packet(session, first_index, count=5, firmware_gap=False, value=0):
    """A 1-channel Signal notification with ``count`` samples of ``value``."""
    sample = (value & 0xFFFFFF).to_bytes(3, "big")
    return struct.pack("<BBHI", 1 if firmware_gap else 0, count, session, first_index & 0xFFFFFFFF) + sample * count


class SessionTrackerTests(unittest.TestCase):
    def test_drops_packets_before_begin_and_of_other_sessions(self):
        t = SignalSessionTracker(channel_count=1)
        self.assertIsNone(t.accept(packet(1, 0)))
        t.begin(2, 0.5)
        self.assertIsNone(t.accept(packet(1, 0)))
        p = t.accept(packet(2, 0))
        self.assertIsNotNone(p)
        self.assertEqual(p.microvolts_per_count, 0.5)
        t.end()
        self.assertIsNone(t.accept(packet(2, 5)))

    def test_marks_gap_when_index_does_not_continue(self):
        t = SignalSessionTracker(1)
        t.begin(7, 1.0)
        self.assertFalse(t.accept(packet(7, 0)).gap_before)
        self.assertFalse(t.accept(packet(7, 5)).gap_before)
        self.assertTrue(t.accept(packet(7, 15)).gap_before)  # 10..14 lost
        self.assertFalse(t.accept(packet(7, 20)).gap_before)

    def test_keeps_firmware_and_app_gaps(self):
        t = SignalSessionTracker(1)
        t.begin(1, 1.0)
        self.assertTrue(t.accept(packet(1, 0, firmware_gap=True)).gap_before)
        t.mark_gap()
        self.assertTrue(t.accept(packet(1, 5)).gap_before)
        self.assertFalse(t.accept(packet(1, 10)).gap_before)

    def test_index_wraps_at_32_bits(self):
        t = SignalSessionTracker(1)
        t.begin(1, 1.0)
        t.accept(packet(1, 0xFFFF_FFFD, count=3))
        self.assertFalse(t.accept(packet(1, 0)).gap_before)

    def test_begin_resets_index_tracking(self):
        t = SignalSessionTracker(1)
        t.begin(1, 1.0)
        t.accept(packet(1, 100))
        t.begin(2, 2.0)
        self.assertFalse(t.accept(packet(2, 0)).gap_before)

    def test_microvolts_use_session_scale(self):
        t = SignalSessionTracker(1)
        t.begin(3, 0.25)
        p = t.accept(packet(3, 0, count=1, value=-2))
        self.assertEqual(p.samples[0][0], -2)
        self.assertEqual(p.microvolts[0][0], -0.5)


if __name__ == "__main__":
    unittest.main()
