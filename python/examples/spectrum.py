"""Live band powers: filters the EEG and prints delta-gamma shares once per second.

    py -3 examples/spectrum.py                  # nearest device, 60 s, 50 Hz mains
    py -3 examples/spectrum.py --mains 60 --seconds 120

Close your eyes for a few seconds: alpha (8-13 Hz) rises on most people.
"""

import argparse
import asyncio
import time

import blueline
from blueline import EEG_BANDS, SignalFilter, SpectrumAnalyzer


async def main(args):
    target = args.address or await blueline.find(timeout=10)
    if target is None:
        raise SystemExit("No BlueLine found.")

    async with await blueline.connect(target) as device:
        info = device.info
        print(f"Connected {device.name} (firmware {info.firmware_version})")
        filt = SignalFilter(info.channel_count, info.signal_rate_hz, notch=args.mains)
        analyzer = SpectrumAnalyzer(info.channel_count, info.signal_rate_hz, window=4.0, update_rate=1.0)
        cpu = 0.0
        latest = []

        def on_signal(packet: blueline.SignalPacket):
            nonlocal cpu
            t = time.process_time()
            filt.process(packet)              # filtered µV for display, [sample][channel]
            latest.extend(analyzer.process(packet))
            cpu += time.process_time() - t

        device.on_signal = on_signal
        await device.start_signal()
        print("Filling the 4 s window...")
        print("time  ch  " + "  ".join(f"{b:>6s}" for b in EEG_BANDS) + "   (share of total, %)")

        start = time.monotonic()
        while time.monotonic() - start < args.seconds and device.is_connected:
            await asyncio.sleep(0.2)
            while latest:
                frame = latest.pop(0)
                for c, ch in enumerate(frame.channels):
                    print(f"{frame.end_time(info.signal_rate_hz):4.0f}s  {c + 1}   "
                          + "  ".join(f"{100 * ch.relative[b]:6.1f}" for b in EEG_BANDS))
        elapsed = time.monotonic() - start
        print(f"Processing used {100 * cpu / elapsed:.1f}% of one CPU core")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--address")
    p.add_argument("--seconds", type=int, default=60)
    p.add_argument("--mains", type=float, default=50.0, choices=[50.0, 60.0], help="mains frequency for the notch")
    asyncio.run(main(p.parse_args()))
