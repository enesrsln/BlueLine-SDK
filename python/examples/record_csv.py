"""Record EEG (and accelerometer) from the nearest BlueLine to CSV files.

    py -3 examples/record_csv.py --seconds 120 --out session1
    -> session1_eeg.csv, session1_mems.csv
"""

import argparse
import asyncio

import blueline
from blueline.recording import CsvRecorder


async def main(args):
    target = args.address or await blueline.find(timeout=10)
    if target is None:
        raise SystemExit("No BlueLine found.")

    async with await blueline.connect(target) as device:
        print(f"Connected {device.name} (serial {device.serial_number}, firmware {device.info.firmware_version})")
        if args.gain:
            await device.set_gain(args.gain)
        with CsvRecorder(f"{args.out}_eeg.csv", device.info.signal_rate_hz,
                         mems_path=None if args.no_mems else f"{args.out}_mems.csv") as rec:
            device.on_signal = rec.write_signal
            device.on_mems = rec.write_mems
            await device.start_signal()
            if not args.no_mems:
                await device.start_mems()
            print(f"Recording {args.seconds} s, gain {device.info.gain}... (Ctrl+C to stop early)")
            try:
                for _ in range(args.seconds):
                    await asyncio.sleep(1)
                    if not device.is_connected:
                        print("Connection lost.")
                        break
            finally:
                device.on_signal = device.on_mems = None
                if device.is_connected:
                    await device.stop_signal()
                status = device.status
                print(f"Wrote {rec.samples_written} samples, {rec.gaps} gaps"
                      + (f", device dropped {status.signal_samples_dropped}" if status else ""))


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--address")
    p.add_argument("--seconds", type=int, default=60)
    p.add_argument("--gain", type=int, choices=blueline.SUPPORTED_GAINS)
    p.add_argument("--out", default="blueline")
    p.add_argument("--no-mems", action="store_true")
    try:
        asyncio.run(main(p.parse_args()))
    except KeyboardInterrupt:
        pass
