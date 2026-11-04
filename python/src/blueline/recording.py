"""Write EEG and accelerometer data to CSV files.

::

    with CsvRecorder("eeg.csv", mems_path="mems.csv") as rec:
        device.on_signal = rec.write_signal
        device.on_mems = rec.write_mems
        await device.start_signal()
        ...

EEG file, one row per sample::

    session,index,time_s,gap_before,ch1_uv,ch2_uv,ch3_uv,ch4_uv

``time_s`` is ``index / signal_rate_hz`` since the session started; ``gap_before``
is 1 on the first sample after lost samples. MEMS file::

    session,mems_index,signal_index,x_g,y_g,z_g
"""

from __future__ import annotations

import csv
from typing import Optional, TextIO

from .protocol import MemsSample, SignalPacket


class CsvRecorder:
    def __init__(self, path: str, signal_rate_hz: float = 250.0, mems_path: Optional[str] = None,
                 raw_counts: bool = False):
        """``raw_counts=True`` writes ADC counts instead of microvolts (columns ``chN_counts``)."""
        self._rate = float(signal_rate_hz)
        self._raw = raw_counts
        self._file: TextIO = open(path, "w", newline="", encoding="utf-8")
        self._writer = csv.writer(self._file)
        self._channels: Optional[int] = None
        self._mems_file: Optional[TextIO] = None
        self._mems_writer = None
        if mems_path:
            self._mems_file = open(mems_path, "w", newline="", encoding="utf-8")
            self._mems_writer = csv.writer(self._mems_file)
            self._mems_writer.writerow(["session", "mems_index", "signal_index", "x_g", "y_g", "z_g"])
        self.samples_written = 0
        self.gaps = 0
        self.closed = False

    def write_signal(self, packet: SignalPacket) -> None:
        # Packets already in flight may still arrive after close(): ignore them.
        if self.closed:
            return
        if self._channels is None:
            self._channels = packet.channel_count
            unit = "counts" if self._raw else "uv"
            self._writer.writerow(["session", "index", "time_s", "gap_before"]
                                  + [f"ch{c + 1}_{unit}" for c in range(self._channels)])
        rows = packet.samples if self._raw else packet.microvolts
        if packet.gap_before:
            self.gaps += 1
        for i, values in enumerate(rows):
            index = (packet.first_index + i) & 0xFFFF_FFFF
            gap = 1 if (i == 0 and packet.gap_before) else 0
            cells = values if self._raw else [f"{v:.4f}" for v in values]
            self._writer.writerow([packet.session, index, f"{index / self._rate:.4f}", gap, *cells])
        self.samples_written += len(rows)

    def write_mems(self, sample: MemsSample) -> None:
        if self._mems_writer is None or self.closed:
            return
        self._mems_writer.writerow([sample.session, sample.mems_index,
                                    "" if sample.signal_index is None else sample.signal_index,
                                    f"{sample.x_g:.4f}", f"{sample.y_g:.4f}", f"{sample.z_g:.4f}"])

    def close(self) -> None:
        """Closes the files. Later ``write_*`` calls are ignored."""
        self.closed = True
        self._file.close()
        if self._mems_file:
            self._mems_file.close()

    def __enter__(self) -> "CsvRecorder":
        return self

    def __exit__(self, *exc) -> None:
        self.close()
