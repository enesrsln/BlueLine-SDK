"""Connect to the nearest BlueLine and print one line per second.

    py -3 examples/stream.py                 # nearest device, 30 s
    py -3 examples/stream.py --seconds 60 --gain 12 --address AA:BB:CC:DD:EE:FF
"""

import argparse
import asyncio
import statistics

import blueline


async def main(args):
    if args.address:
        target = args.address
    else:
        print("Scanning...")
        found = await blueline.discover(timeout=5)
        if not found:
            raise SystemExit("No BlueLine found. Is it switched on and not connected to another app?")
        for d in found:
            print(f"  {d.name}  {d.address}  {d.rssi} dBm")
        target = found[0]

    async with await blueline.connect(target) as device:
        info = device.info
        print(f"Connected {device.name}: firmware {info.firmware_version}, serial {device.serial_number}, "
              f"{info.channel_count} channels at {info.signal_rate_hz} Hz, MTU {device.mtu}")
        if args.gain:
            await device.set_gain(args.gain)

        second = []
        gaps = 0

        def on_signal(packet: blueline.SignalPacket):
            nonlocal gaps
            gaps += packet.gap_before
            second.extend(packet.microvolts)

        device.on_signal = on_signal
        device.on_disconnect = lambda error: print("Disconnected", error or "")
        session = await device.start_signal()
        print(f"Session {session}, gain {device.info.gain}")

        for t in range(args.seconds):
            await asyncio.sleep(1)
            if not device.is_connected:
                break
            chunk, second[:] = list(second), []
            if chunk:
                means = [statistics.fmean(ch) for ch in zip(*chunk)]
                print(f"{t + 1:4d}s  {len(chunk):3d} samples  gaps {gaps}  mean uV "
                      + "  ".join(f"{m:9.1f}" for m in means)
                      + f"  battery {device.status.battery_percent if device.status else '?'}%")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--address", help="connect to this device instead of the nearest one")
    p.add_argument("--seconds", type=int, default=30)
    p.add_argument("--gain", type=int, choices=blueline.SUPPORTED_GAINS)
    asyncio.run(main(p.parse_args()))
