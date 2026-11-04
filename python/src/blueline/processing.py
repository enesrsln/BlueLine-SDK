"""EEG signal processing: filters, spectrum and band powers.

Pure standard library (NumPy is used for the FFT when installed), and the same
algorithms as the other BlueLine SDKs, checked by
``testvectors/blueline_processing_v1.json``.

Live filtering, one filter chain per channel::

    filt = SignalFilter(channel_count=4, sample_rate=250)          # 0.5-40 Hz + 50 Hz notch
    device.on_signal = lambda packet: show(filt.process(packet))   # [sample][channel] in µV

Live spectrum and band powers::

    analyzer = SpectrumAnalyzer(channel_count=4, sample_rate=250)  # 4 s window, 5 updates/s
    def on_signal(packet):
        for frame in analyzer.process(packet):
            print(frame.channels[0].relative["alpha"])

Both reset themselves on a new session or after lost samples, so data from
before a gap never mixes with data after it.
"""

from __future__ import annotations

import cmath
import math
from collections import deque
from dataclasses import dataclass
from typing import Deque, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

from .protocol import SignalPacket

#: Default EEG bands in Hz, ``[low, high)``.
EEG_BANDS: Dict[str, Tuple[float, float]] = {
    "delta": (1.0, 4.0),
    "theta": (4.0, 8.0),
    "alpha": (8.0, 13.0),
    "beta": (13.0, 30.0),
    "gamma": (30.0, 45.0),
}

Rows = Sequence[Sequence[float]]


# --------------------------------------------------------------------- filters


class Biquad:
    """One second-order IIR section (direct form II transposed).

    Coefficients are normalized so that ``a0 == 1``. The section starts in the
    steady state of its first input sample, so a large electrode offset does not
    ring through a high-pass filter.
    """

    __slots__ = ("b0", "b1", "b2", "a1", "a2", "_s1", "_s2", "_started")

    def __init__(self, b0: float, b1: float, b2: float, a1: float, a2: float):
        self.b0, self.b1, self.b2, self.a1, self.a2 = b0, b1, b2, a1, a2
        self.reset()

    @property
    def coefficients(self) -> Tuple[float, float, float, float, float]:
        """``(b0, b1, b2, a1, a2)``."""
        return self.b0, self.b1, self.b2, self.a1, self.a2

    @property
    def dc_gain(self) -> float:
        return (self.b0 + self.b1 + self.b2) / (1.0 + self.a1 + self.a2)

    def reset(self) -> None:
        """Forget the past; the next sample sets the starting state again."""
        self._s1 = self._s2 = 0.0
        self._started = False

    def filter(self, x: float) -> float:
        if not self._started:
            g = self.dc_gain
            self._s2 = (self.b2 - self.a2 * g) * x
            self._s1 = (self.b1 - self.a1 * g) * x + self._s2
            self._started = True
        y = self.b0 * x + self._s1
        self._s1 = self.b1 * x - self.a1 * y + self._s2
        self._s2 = self.b2 * x - self.a2 * y
        return y


def _butterworth_qs(order: int) -> List[float]:
    if order < 2 or order % 2:
        raise ValueError("order must be an even number >= 2")
    n = order // 2
    return [1.0 / (2.0 * math.cos(math.pi * (2 * k + 1) / (2 * order))) for k in range(n)]


def _check_frequency(sample_rate: float, frequency: float) -> float:
    if not 0.0 < frequency < sample_rate / 2.0:
        raise ValueError(f"frequency must be between 0 and {sample_rate / 2:g} Hz (Nyquist), got {frequency:g}")
    return 2.0 * math.pi * frequency / sample_rate


def _lowpass_section(w0: float, q: float) -> Biquad:
    cos, alpha = math.cos(w0), math.sin(w0) / (2.0 * q)
    a0 = 1.0 + alpha
    b = (1.0 - cos) / 2.0 / a0
    return Biquad(b, 2.0 * b, b, -2.0 * cos / a0, (1.0 - alpha) / a0)


def _highpass_section(w0: float, q: float) -> Biquad:
    cos, alpha = math.cos(w0), math.sin(w0) / (2.0 * q)
    a0 = 1.0 + alpha
    b = (1.0 + cos) / 2.0 / a0
    return Biquad(b, -2.0 * b, b, -2.0 * cos / a0, (1.0 - alpha) / a0)


class Filter:
    """A cascade of biquads for one channel.

    Build one with the class methods, chain several with :class:`FilterList`.
    """

    def __init__(self, sections: Iterable[Biquad], description: str = "custom"):
        self.sections: Tuple[Biquad, ...] = tuple(sections)
        self.description = description

    @classmethod
    def lowpass(cls, sample_rate: float, cutoff: float, order: int = 4) -> "Filter":
        """Butterworth low-pass; ``order`` 2, 4, 6 or 8 (-3 dB at ``cutoff``)."""
        w0 = _check_frequency(sample_rate, cutoff)
        return cls((_lowpass_section(w0, q) for q in _butterworth_qs(order)), f"lowpass {cutoff:g} Hz")

    @classmethod
    def highpass(cls, sample_rate: float, cutoff: float, order: int = 4) -> "Filter":
        """Butterworth high-pass; removes the electrode offset and slow drift."""
        w0 = _check_frequency(sample_rate, cutoff)
        return cls((_highpass_section(w0, q) for q in _butterworth_qs(order)), f"highpass {cutoff:g} Hz")

    @classmethod
    def notch(cls, sample_rate: float, frequency: float = 50.0, quality: float = 30.0) -> "Filter":
        """Narrow band-stop for mains interference: 50 Hz (Europe, Turkey) or 60 Hz.

        The -3 dB width is ``frequency / quality`` (1.7 Hz at 50 Hz with the default).
        """
        w0 = _check_frequency(sample_rate, frequency)
        if quality <= 0:
            raise ValueError("quality must be positive")
        bw = w0 / quality
        g = 1.0 / (1.0 + math.tan(bw / 2.0))
        cos = math.cos(w0)
        return cls([Biquad(g, -2.0 * g * cos, g, -2.0 * g * cos, 2.0 * g - 1.0)], f"notch {frequency:g} Hz")

    @classmethod
    def bandpass(cls, sample_rate: float, low: float, high: float, order: int = 4) -> "Filter":
        """High-pass at ``low`` followed by low-pass at ``high``."""
        if not low < high:
            raise ValueError("low must be below high")
        hp, lp = cls.highpass(sample_rate, low, order), cls.lowpass(sample_rate, high, order)
        return cls(hp.sections + lp.sections, f"bandpass {low:g}-{high:g} Hz")

    def reset(self) -> None:
        for s in self.sections:
            s.reset()

    def filter(self, x: float) -> float:
        for s in self.sections:
            x = s.filter(x)
        return x

    def filter_array(self, values: Iterable[float]) -> List[float]:
        return [self.filter(v) for v in values]

    def response(self, frequency: float, sample_rate: float) -> float:
        """Magnitude response (1.0 = passes unchanged) at ``frequency``."""
        z = cmath.exp(-2j * math.pi * frequency / sample_rate)
        h = 1.0 + 0j
        for s in self.sections:
            h *= (s.b0 + s.b1 * z + s.b2 * z * z) / (1.0 + s.a1 * z + s.a2 * z * z)
        return abs(h)

    def copy(self) -> "Filter":
        """Same coefficients, fresh state (for another channel)."""
        return Filter((Biquad(*s.coefficients) for s in self.sections), self.description)

    def __repr__(self) -> str:
        return f"Filter({self.description}, {len(self.sections)} sections)"


class FilterList:
    """Filters applied one after another to a single channel."""

    def __init__(self, filters: Iterable[Filter] = ()):
        self.filters: List[Filter] = list(filters)

    def add(self, f: Filter) -> None:
        self.filters.append(f)

    def reset(self) -> None:
        for f in self.filters:
            f.reset()

    def filter(self, x: float) -> float:
        for f in self.filters:
            x = f.filter(x)
        return x

    def filter_array(self, values: Iterable[float]) -> List[float]:
        return [self.filter(v) for v in values]

    def response(self, frequency: float, sample_rate: float) -> float:
        r = 1.0
        for f in self.filters:
            r *= f.response(frequency, sample_rate)
        return r

    def copy(self) -> "FilterList":
        return FilterList(f.copy() for f in self.filters)


class _Continuity:
    """Detects a new session or lost samples between packets."""

    def __init__(self):
        self.session: Optional[int] = None

    def broken(self, packet: SignalPacket) -> bool:
        broken = packet.gap_before or packet.session != self.session
        self.session = packet.session
        return broken


class SignalFilter:
    """The same filter chain on every channel of a stream.

    Default: 0.5-40 Hz band-pass (4th-order Butterworth) and a 50 Hz notch.
    Pass ``notch=60`` in the Americas, ``None`` to leave a stage out, or your own
    ``filters`` (a list of :class:`Filter`) to replace the defaults.
    """

    def __init__(self, channel_count: int, sample_rate: float = 250.0, highpass: Optional[float] = 0.5,
                 lowpass: Optional[float] = 40.0, notch: Optional[float] = 50.0, order: int = 4,
                 filters: Optional[Iterable[Filter]] = None):
        self.sample_rate = float(sample_rate)
        if filters is None:
            chain = []
            if highpass is not None:
                chain.append(Filter.highpass(sample_rate, highpass, order))
            if lowpass is not None:
                chain.append(Filter.lowpass(sample_rate, lowpass, order))
            if notch is not None:
                chain.append(Filter.notch(sample_rate, notch))
        else:
            chain = [f.copy() for f in filters]
        template = FilterList(chain)
        self.channels: Tuple[FilterList, ...] = tuple(template.copy() for _ in range(channel_count))
        self._continuity = _Continuity()

    def reset(self) -> None:
        for ch in self.channels:
            ch.reset()

    def filter_rows(self, rows: Rows) -> List[List[float]]:
        """Filters ``[sample][channel]`` values that continue the previous call."""
        chans = self.channels
        return [[chans[c].filter(v) for c, v in enumerate(row)] for row in rows]

    def process(self, packet: SignalPacket) -> List[List[float]]:
        """Filtered microvolts of ``packet`` as ``[sample][channel]``.

        Resets first when the packet starts a new session or follows lost samples.
        Allow the filters 1-2 s to settle after a reset.
        """
        if self._continuity.broken(packet):
            self.reset()
        return self.filter_rows(packet.microvolts)


# -------------------------------------------------------------------- spectrum


def _fft(values: Sequence[complex]) -> List[complex]:
    """Radix-2 FFT; ``len(values)`` must be a power of two."""
    n = len(values)
    out = list(values)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            out[i], out[j] = out[j], out[i]
    size = 2
    while size <= n:
        step = cmath.exp(-2j * math.pi / size)
        half = size // 2
        for start in range(0, n, size):
            w = 1.0 + 0j
            for k in range(start, start + half):
                t = w * out[k + half]
                out[k + half] = out[k] - t
                out[k] += t
                w *= step
        size *= 2
    return out


try:  # NumPy is optional; it only makes the FFT faster.
    import numpy as _np
except ImportError:  # pragma: no cover
    _np = None


def _power_of_two_at_least(n: int) -> int:
    return 1 << max(0, (n - 1).bit_length())


def hann_window(n: int) -> List[float]:
    """Periodic Hann window (as used for spectral analysis)."""
    return [0.5 - 0.5 * math.cos(2.0 * math.pi * i / n) for i in range(n)]


def power_spectrum(values: Sequence[float], sample_rate: float, nfft: Optional[int] = None,
                   max_frequency: Optional[float] = None) -> Tuple[List[float], List[float]]:
    """One-sided power spectral density of one channel.

    The mean is removed and a Hann window applied; the segment is zero-padded to
    ``nfft`` (default: the next power of two). Returns ``(frequencies_hz,
    psd_uv2_per_hz)`` for microvolt input, up to ``max_frequency`` if given.
    Matches ``scipy.signal.periodogram(x, fs, window="hann", nfft=nfft)``.
    """
    n = len(values)
    if n < 2:
        raise ValueError("need at least 2 samples")
    nfft = nfft or _power_of_two_at_least(n)
    if nfft < n or nfft & (nfft - 1):
        raise ValueError("nfft must be a power of two and at least len(values)")
    mean = math.fsum(values) / n
    window = hann_window(n)
    scale = 1.0 / (sample_rate * math.fsum(w * w for w in window))
    segment = [(v - mean) * w for v, w in zip(values, window)]
    bins = nfft // 2 + 1
    if _np is not None:
        spectrum = _np.fft.rfft(_np.asarray(segment, dtype=float), nfft)
        power = (spectrum.real ** 2 + spectrum.imag ** 2).tolist()
    else:
        spectrum = _fft(segment + [0.0] * (nfft - n))
        power = [abs(c) ** 2 for c in spectrum[:bins]]
    psd = [p * scale * (1.0 if k == 0 or k == nfft // 2 else 2.0) for k, p in enumerate(power)]
    df = sample_rate / nfft
    freqs = [k * df for k in range(bins)]
    if max_frequency is not None:
        keep = sum(1 for f in freqs if f <= max_frequency)
        freqs, psd = freqs[:keep], psd[:keep]
    return freqs, psd


def band_powers(frequencies: Sequence[float], psd: Sequence[float],
                bands: Mapping[str, Tuple[float, float]] = EEG_BANDS) -> Dict[str, float]:
    """Power in each band (µV² for a µV spectrum): PSD summed over ``low <= f < high``."""
    if len(frequencies) < 2:
        raise ValueError("need at least 2 frequency bins")
    df = frequencies[1] - frequencies[0]
    return {name: math.fsum(p for f, p in zip(frequencies, psd) if lo <= f < hi) * df
            for name, (lo, hi) in bands.items()}


def relative_powers(powers: Mapping[str, float], bands: Mapping[str, Tuple[float, float]] = EEG_BANDS,
                    normalize_by_bandwidth: bool = False) -> Dict[str, float]:
    """Each band's share of the total, summing to 1.

    With ``normalize_by_bandwidth`` each band is first divided by its width in
    Hz, so wide bands (beta) do not dominate narrow ones (theta).
    """
    if normalize_by_bandwidth:
        powers = {k: v / (bands[k][1] - bands[k][0]) for k, v in powers.items()}
    total = math.fsum(powers.values())
    return {k: (v / total if total > 0 else 0.0) for k, v in powers.items()}


@dataclass(frozen=True)
class ChannelSpectrum:
    #: PSD in µV²/Hz at :attr:`SpectrumFrame.frequencies`.
    psd: Tuple[float, ...]
    #: Absolute band power in µV².
    powers: Dict[str, float]
    #: Share of each band in the total of all bands (sums to 1).
    relative: Dict[str, float]


@dataclass(frozen=True)
class SpectrumFrame:
    """Spectrum of the last ``window`` seconds of every channel."""

    session: int
    #: Index of the sample after the window (the window ends at ``end_index - 1``).
    end_index: int
    frequencies: Tuple[float, ...]
    channels: Tuple[ChannelSpectrum, ...]

    def end_time(self, sample_rate: float) -> float:
        """Seconds since the session started at the end of the window."""
        return self.end_index / sample_rate


class SpectrumAnalyzer:
    """Sliding-window spectrum and band powers of every channel.

    Keeps the last ``window`` seconds (default 4 s = 1000 samples at 250 Hz,
    0.24 Hz resolution) and computes a :class:`SpectrumFrame` ``update_rate``
    times per second once the window is full. After a new session or lost
    samples the window starts filling again, so a frame never spans a gap.

    Feed it raw microvolts: the mean of each window is removed, and the
    spectrum is not affected by the electrode offset. Filtering first with
    :class:`SignalFilter` is fine too.
    """

    def __init__(self, channel_count: int, sample_rate: float = 250.0, window: float = 4.0,
                 update_rate: float = 5.0, max_frequency: float = 50.0,
                 bands: Mapping[str, Tuple[float, float]] = EEG_BANDS, normalize_by_bandwidth: bool = False):
        self.channel_count = channel_count
        self.sample_rate = float(sample_rate)
        self.window_samples = int(round(window * sample_rate))
        self.step_samples = max(1, int(round(sample_rate / update_rate)))
        if self.window_samples < 16:
            raise ValueError("window too short")
        self.max_frequency = max_frequency
        self.bands = dict(bands)
        self.normalize_by_bandwidth = normalize_by_bandwidth
        self._continuity = _Continuity()
        self.reset()

    def reset(self) -> None:
        self._buffer: List[Deque[float]] = [deque(maxlen=self.window_samples) for _ in range(self.channel_count)]
        self._until_next = self.window_samples
        self._next_index: Optional[int] = None

    @property
    def fill(self) -> float:
        """How full the window is, 0.0-1.0 (1.0 once frames are produced)."""
        return min(1.0, len(self._buffer[0]) / self.window_samples)

    def process(self, packet: SignalPacket) -> List[SpectrumFrame]:
        """Adds a packet; returns the frames completed by it (often none, sometimes one)."""
        if self._continuity.broken(packet):
            self.reset()
        return self.add_rows(packet.microvolts, packet.session, packet.first_index)

    def add_rows(self, rows: Rows, session: int = 0, first_index: Optional[int] = None) -> List[SpectrumFrame]:
        """Adds ``[sample][channel]`` values that continue the previous call."""
        index = self._next_index if first_index is None else first_index
        index = index or 0
        frames: List[SpectrumFrame] = []
        buffers = self._buffer
        for row in rows:
            for c, buf in enumerate(buffers):
                buf.append(row[c])
            index += 1
            self._until_next -= 1
            if self._until_next <= 0:
                self._until_next = self.step_samples
                frames.append(self._compute(session, index & 0xFFFF_FFFF))
        self._next_index = index
        return frames

    def _compute(self, session: int, end_index: int) -> SpectrumFrame:
        channels = []
        freqs: List[float] = []
        for buf in self._buffer:
            freqs, psd = power_spectrum(buf, self.sample_rate, max_frequency=self.max_frequency)
            powers = band_powers(freqs, psd, self.bands)
            channels.append(ChannelSpectrum(tuple(psd), powers,
                                            relative_powers(powers, self.bands, self.normalize_by_bandwidth)))
        return SpectrumFrame(session, end_index, tuple(freqs), tuple(channels))


__all__ = [
    "EEG_BANDS", "Biquad", "Filter", "FilterList", "SignalFilter", "hann_window", "power_spectrum",
    "band_powers", "relative_powers", "ChannelSpectrum", "SpectrumFrame", "SpectrumAnalyzer",
]
