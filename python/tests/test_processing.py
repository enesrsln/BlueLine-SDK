import json
import math
import pathlib
import unittest

from blueline import SignalPacket
from blueline import processing as bp

FS = 250.0
VECTORS = json.loads(
    (pathlib.Path(__file__).resolve().parents[2] / "testvectors" / "blueline_processing_v1.json").read_text("utf-8")
)


def sine(freq, amp=1.0, n=1000, offset=0.0):
    return [offset + amp * math.sin(2 * math.pi * freq * i / FS) for i in range(n)]


def packet(session, first, rows, gap=False):
    # microvolts_per_count 1.0: counts are microvolts
    return SignalPacket(gap, session, first, tuple(tuple(r) for r in rows), 1.0)


class SharedVectorTests(unittest.TestCase):
    def assertClose(self, actual, expected):
        self.assertEqual(len(actual), len(expected))
        tol = 1e-9 * max(1e-12, max(abs(v) for v in expected))
        for a, e in zip(actual, expected):
            self.assertLessEqual(abs(a - e), tol)

    def make(self, case):
        t = case["type"]
        if t == "notch":
            return bp.Filter.notch(case["sampleRate"], case["frequency"], case["quality"])
        return getattr(bp.Filter, t)(case["sampleRate"], case["frequency"], case["order"])

    def test_filters(self):
        for case in VECTORS["filters"]:
            with self.subTest(case["name"]):
                f = self.make(case)
                self.assertClose([c for s in f.sections for c in s.coefficients],
                                 [c for s in case["sections"] for c in s])
                self.assertClose(f.filter_array(case["input"]), case["output"])

    def test_default_signal_filter(self):
        case = VECTORS["signalFilterDefault"]
        filt = bp.SignalFilter(1, case["sampleRate"])
        self.assertClose([r[0] for r in filt.filter_rows([[v] for v in case["input"]])], case["output"])

    def test_spectrum(self):
        for case in VECTORS["spectrum"]:
            with self.subTest(case["name"]):
                freqs, psd = bp.power_spectrum(case["input"], case["sampleRate"], case["nfft"], case["maxFrequency"])
                self.assertClose(freqs, case["frequencies"])
                self.assertClose(psd, case["psd"])
                powers = bp.band_powers(freqs, psd, VECTORS["bands"])
                self.assertClose(list(powers.values()), list(case["bandPowers"].values()))
                if "relative" in case:
                    self.assertClose(list(bp.relative_powers(powers).values()), list(case["relative"].values()))
                    self.assertClose(list(bp.relative_powers(powers, normalize_by_bandwidth=True).values()),
                                     list(case["relativeNormalizedByBandwidth"].values()))

    def test_pure_python_fft_matches(self):
        saved = bp._np
        try:
            bp._np = None
            case = VECTORS["spectrum"][0]
            _, psd = bp.power_spectrum(case["input"], FS, 1024, 50.0)
            self.assertClose(psd, case["psd"])
        finally:
            bp._np = saved


class FilterTests(unittest.TestCase):
    def test_notch_removes_mains_and_passes_eeg(self):
        f = bp.Filter.notch(FS, 50)
        self.assertLess(f.response(50, FS), 1e-6)
        self.assertAlmostEqual(f.response(10, FS), 1.0, delta=0.01)
        self.assertAlmostEqual(f.response(50 + 50 / 30 / 2, FS), math.sqrt(0.5), delta=0.01)

    def test_butterworth_is_3db_at_cutoff(self):
        for order in (2, 4, 6, 8):
            self.assertAlmostEqual(bp.Filter.lowpass(FS, 40, order).response(40, FS), math.sqrt(0.5), places=9)
            self.assertAlmostEqual(bp.Filter.highpass(FS, 0.5, order).response(0.5, FS), math.sqrt(0.5), places=9)

    def test_offset_does_not_ring(self):
        # A constant 10 mV electrode offset: the high-pass output stays at zero from the first sample.
        f = bp.Filter.highpass(FS, 0.5)
        self.assertLess(max(abs(v) for v in f.filter_array([10000.0] * 500)), 1e-6)

    def test_default_chain_keeps_alpha_and_removes_rest(self):
        filt = bp.SignalFilter(1, FS)
        x = [a + b + c for a, b, c in zip(sine(10, 30, 2500, 10000), sine(50, 20, 2500), sine(0.05, 200, 2500))]
        y = [r[0] for r in filt.filter_rows([[v] for v in x])][-1000:]
        expected = sine(10, 30, 2500)[-1000:]
        # 10 Hz passes (with the filter's phase shift); compare amplitudes.
        self.assertAlmostEqual(max(y), max(expected), delta=1.0)
        self.assertLess(abs(sum(y) / len(y)), 1.0)

    def test_signal_filter_channels_are_independent(self):
        filt = bp.SignalFilter(2, FS)
        out = filt.filter_rows([[0.0, 1000.0]] * 10 + [[0.0, 0.0]])
        self.assertTrue(all(r[0] == 0.0 for r in out))
        self.assertNotEqual(out[-1][1], 0.0)

    def test_signal_filter_resets_on_gap_and_session(self):
        filt = bp.SignalFilter(1, FS)
        filt.process(packet(1, 0, [[0.0]] * 5))
        # Without a reset, a jump to 5000 would ring through the high-pass filter.
        self.assertNotAlmostEqual(filt.process(packet(1, 5, [[5000.0]]))[0][0], 0.0, places=3)
        self.assertAlmostEqual(filt.process(packet(1, 20, [[5000.0]], gap=True))[0][0], 0.0, places=6)
        self.assertAlmostEqual(filt.process(packet(2, 0, [[-300.0]]))[0][0], 0.0, places=6)

    def test_invalid_parameters(self):
        with self.assertRaises(ValueError):
            bp.Filter.lowpass(FS, 125)
        with self.assertRaises(ValueError):
            bp.Filter.highpass(FS, 1, order=3)
        with self.assertRaises(ValueError):
            bp.Filter.bandpass(FS, 40, 1)
        with self.assertRaises(ValueError):
            bp.Filter.notch(FS, 50, 0)


class SpectrumTests(unittest.TestCase):
    def test_sine_power_and_peak(self):
        freqs, psd = bp.power_spectrum(sine(10, 30, offset=5000), FS)
        peak = freqs[max(range(len(psd)), key=psd.__getitem__)]
        self.assertAlmostEqual(peak, 10.0, delta=FS / 1024)
        powers = bp.band_powers(freqs, psd)
        self.assertAlmostEqual(powers["alpha"], 30 ** 2 / 2, delta=1.0)  # Parseval: A^2 / 2
        self.assertLess(powers["delta"], 1e-6)  # offset removed
        rel = bp.relative_powers(powers)
        self.assertAlmostEqual(sum(rel.values()), 1.0)
        self.assertGreater(rel["alpha"], 0.99)

    def test_normalize_by_bandwidth(self):
        powers = {"theta": 4.0, "beta": 17.0}
        bands = {"theta": (4.0, 8.0), "beta": (13.0, 30.0)}
        self.assertEqual(bp.relative_powers(powers, bands, normalize_by_bandwidth=True), {"theta": 0.5, "beta": 0.5})
        self.assertEqual(bp.relative_powers({"theta": 0.0}, {"theta": (4.0, 8.0)}), {"theta": 0.0})


class AnalyzerTests(unittest.TestCase):
    def feed(self, analyzer, session, first, values, gap=False, size=10):
        frames = []
        for i in range(0, len(values), size):
            rows = [[v, -v] for v in values[i:i + size]]
            frames += analyzer.process(packet(session, first + i, rows, gap and i == 0))
        return frames

    def test_frames_after_window_then_every_step(self):
        an = bp.SpectrumAnalyzer(2, FS, window=4, update_rate=5)
        frames = self.feed(an, 1, 0, sine(10, 30, 1500))
        self.assertEqual([f.end_index for f in frames], list(range(1000, 1501, 50)))
        self.assertEqual(an.fill, 1.0)
        last = frames[-1]
        self.assertEqual(last.session, 1)
        self.assertAlmostEqual(last.end_time(FS), 6.0)
        self.assertEqual(len(last.channels), 2)
        self.assertAlmostEqual(last.frequencies[-1], 50.0, delta=FS / 1024)
        self.assertGreater(last.channels[0].relative["alpha"], 0.99)
        self.assertAlmostEqual(last.channels[1].powers["alpha"], last.channels[0].powers["alpha"])

    def test_window_restarts_after_gap_and_new_session(self):
        an = bp.SpectrumAnalyzer(2, FS, window=4, update_rate=5)
        self.feed(an, 1, 0, sine(10, 30, 900))
        self.assertAlmostEqual(an.fill, 0.9)
        self.assertEqual(self.feed(an, 1, 1000, sine(10, 30, 900), gap=True), [])
        self.assertEqual(self.feed(an, 2, 0, sine(10, 30, 990)), [])
        self.assertEqual(len(self.feed(an, 2, 990, sine(10, 30, 10))), 1)


if __name__ == "__main__":
    unittest.main()
