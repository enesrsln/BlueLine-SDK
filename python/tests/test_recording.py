import csv
import os
import tempfile
import unittest

from blueline import MemsSample, SignalPacket
from blueline.recording import CsvRecorder


class RecorderTests(unittest.TestCase):
    def test_writes_samples_with_time_and_gap(self):
        with tempfile.TemporaryDirectory() as tmp:
            eeg, mems = os.path.join(tmp, "eeg.csv"), os.path.join(tmp, "mems.csv")
            with CsvRecorder(eeg, signal_rate_hz=250, mems_path=mems) as rec:
                rec.write_signal(SignalPacket(False, 3, 0, ((1, 2), (3, 4)), 0.5))
                rec.write_signal(SignalPacket(True, 3, 250, ((5, 6),), 0.5))
                rec.write_mems(MemsSample(3, 1, None, 0, 0, 256))
            with open(eeg, newline="") as f:
                rows = list(csv.reader(f))
            self.assertEqual(rows[0], ["session", "index", "time_s", "gap_before", "ch1_uv", "ch2_uv"])
            self.assertEqual(rows[1], ["3", "0", "0.0000", "0", "0.5000", "1.0000"])
            self.assertEqual(rows[3], ["3", "250", "1.0000", "1", "2.5000", "3.0000"])
            self.assertEqual(rec.samples_written, 3)
            self.assertEqual(rec.gaps, 1)
            with open(mems, newline="") as f:
                self.assertEqual(list(csv.reader(f))[1], ["3", "1", "", "0.0000", "0.0000", "0.9984"])

    def test_writes_after_close_are_ignored(self):
        # Packets still in flight when recording stops must not raise.
        with tempfile.TemporaryDirectory() as tmp:
            eeg, mems = os.path.join(tmp, "eeg.csv"), os.path.join(tmp, "mems.csv")
            with CsvRecorder(eeg, mems_path=mems) as rec:
                rec.write_signal(SignalPacket(False, 1, 0, ((1,),), 1.0))
            rec.write_signal(SignalPacket(False, 1, 1, ((2,),), 1.0))
            rec.write_mems(MemsSample(1, 0, 1, 0, 0, 256))
            self.assertTrue(rec.closed)
            self.assertEqual(rec.samples_written, 1)


if __name__ == "__main__":
    unittest.main()
