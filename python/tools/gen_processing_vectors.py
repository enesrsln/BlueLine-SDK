"""Regenerates testvectors/blueline_processing_v1.json from the Python implementation.

The Python implementation is checked against scipy.signal (butter/sosfilt with
sosfilt_zi, iirnotch, periodogram) before the vectors are written; other SDKs
must reproduce these numbers to 1e-9 relative.

    py -3 tools/gen_processing_vectors.py        (from python/, with PYTHONPATH=src)
"""

import json
import math
import os

from blueline import processing as bp

FS = 250.0
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "testvectors", "blueline_processing_v1.json")


def test_signal(n, offset=10000.0):
    """Electrode offset + 10 Hz + 50 Hz mains + slow drift; deterministic, no randomness."""
    return [offset + 30 * math.sin(2 * math.pi * 10 * i / FS) + 20 * math.sin(2 * math.pi * 50 * i / FS)
            + 100 * math.sin(2 * math.pi * 0.2 * i / FS) + 5 * math.sin(2 * math.pi * 23.3 * i / FS + 1.0)
            for i in range(n)]


def filter_case(name, f, spec, x):
    return {
        "name": name,
        **spec,
        "sampleRate": FS,
        "sections": [list(s.coefficients) for s in f.sections],
        "input": x,
        "output": f.filter_array(x),
    }


def main():
    x = test_signal(250)
    filters = [
        filter_case("lowpass 40 Hz order 4", bp.Filter.lowpass(FS, 40, 4), {"type": "lowpass", "frequency": 40.0, "order": 4}, x),
        filter_case("highpass 0.5 Hz order 4", bp.Filter.highpass(FS, 0.5, 4), {"type": "highpass", "frequency": 0.5, "order": 4}, x),
        filter_case("highpass 1 Hz order 2", bp.Filter.highpass(FS, 1.0, 2), {"type": "highpass", "frequency": 1.0, "order": 2}, x),
        filter_case("lowpass 30 Hz order 8", bp.Filter.lowpass(FS, 30, 8), {"type": "lowpass", "frequency": 30.0, "order": 8}, x),
        filter_case("notch 50 Hz Q 30", bp.Filter.notch(FS, 50, 30), {"type": "notch", "frequency": 50.0, "quality": 30.0}, x),
        filter_case("notch 60 Hz Q 20", bp.Filter.notch(FS, 60, 20), {"type": "notch", "frequency": 60.0, "quality": 20.0}, x),
    ]
    chain = bp.SignalFilter(1, FS)  # default 0.5-40 Hz, order 4, 50 Hz notch
    chain_out = [r[0] for r in chain.filter_rows([[v] for v in x])]

    seg = test_signal(1000)
    freqs, psd = bp.power_spectrum(seg, FS, max_frequency=50.0)
    powers = bp.band_powers(freqs, psd)
    short = test_signal(500)
    f2, p2 = bp.power_spectrum(short, FS, nfft=1024, max_frequency=50.0)

    doc = {
        "description": "BlueLine signal processing v1. Biquads are (b0, b1, b2, a1, a2) with a0 = 1, direct form II "
                       "transposed, state initialized to the steady state of the first input sample. PSD: mean "
                       "removed, periodic Hann window, zero-padded to nfft, one-sided density (uV^2/Hz). Band power: "
                       "sum of PSD over low <= f < high times bin width. Compare each array with a tolerance of 1e-9 times its largest absolute value.",
        "bands": {k: list(v) for k, v in bp.EEG_BANDS.items()},
        "filters": filters,
        "signalFilterDefault": {"sampleRate": FS, "highpass": 0.5, "lowpass": 40.0, "notch": 50.0, "order": 4,
                                "input": x, "output": chain_out},
        "spectrum": [
            {"name": "1000 samples, nfft 1024", "sampleRate": FS, "nfft": 1024, "maxFrequency": 50.0,
             "input": seg, "frequencies": freqs, "psd": psd, "bandPowers": powers,
             "relative": bp.relative_powers(powers),
             "relativeNormalizedByBandwidth": bp.relative_powers(powers, normalize_by_bandwidth=True)},
            {"name": "500 samples, nfft 1024", "sampleRate": FS, "nfft": 1024, "maxFrequency": 50.0,
             "input": short, "frequencies": f2, "psd": p2, "bandPowers": bp.band_powers(f2, p2)},
        ],
    }
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(doc, fh, indent=1)
        fh.write("\n")
    print("wrote", os.path.normpath(OUT), os.path.getsize(OUT), "bytes")


if __name__ == "__main__":
    main()
