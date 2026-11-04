# <img src="../docs/assets/icon.svg" width="36" align="top" alt=""> BlueLine SDK for Python

asyncio library for streaming EEG and accelerometer data from **BlueLine**
devices on Windows, macOS and Linux, built on [bleak](https://github.com/hbldh/bleak).
Same feature set and data model as the iOS and Android SDKs.

- Scan, connect, read device info, serial number and firmware
- Multi-channel EEG at 250 Hz, as raw ADC counts or microvolts (NumPy optional)
- 3-axis accelerometer at 100 Hz, raw counts or g
- Gain control, LED identify, battery and status (loss counters, faults)
- Session and lost-sample handling built in
- Filters, spectrum and band powers (delta–gamma)
- CSV recording

Requirements: Python 3.9+, bleak 0.22+, a Bluetooth 4.0+ adapter
(Windows 10 1709+ built-in Bluetooth works).


## Installation

```sh
pip install "blueline-sdk @ git+https://github.com/enesrsln/BlueLine-SDK.git@v1.0.0#subdirectory=python"
pip install "blueline-sdk[numpy] @ git+https://github.com/enesrsln/BlueLine-SDK.git@v1.0.0#subdirectory=python"   # with NumPy support for packet.to_numpy()
```

On Windows use `py -3 -m pip`, on macOS and Linux `python3 -m pip` if `pip`
is not on the path. From a checkout of this repository: `pip install ./python`.

## Quick start

```python
import asyncio
import blueline

async def main():
    found = await blueline.discover(timeout=5)          # strongest signal first
    async with await blueline.connect(found[0]) as device:
        print(device.name, device.info.firmware_version, device.serial_number)

        def on_signal(packet: blueline.SignalPacket):
            if packet.gap_before:
                print("samples lost before index", packet.first_index)
            for offset, channels in enumerate(packet.microvolts):
                seconds = (packet.first_index + offset) / device.info.signal_rate_hz
                # channels: one value per channel, in µV at `seconds` since start_signal

        device.on_signal = on_signal
        device.on_mems = lambda s: None                  # s.x_g, s.y_g, s.z_g
        device.on_disconnect = lambda error: print("disconnected", error or "")

        await device.start_signal()
        await device.start_mems()
        await asyncio.sleep(30)
    # leaving the block sends STOP_SIGNAL and disconnects

asyncio.run(main())
```

Or iterate instead of using a callback:

```python
async for packet in device.signal_packets():
    process(packet.to_numpy())        # (samples, channels) float64 µV
```

Start iterating (for example in a task) before `start_signal()`.

## Examples

| Script | What it does |
|---|---|
| [`examples/stream.py`](examples/stream.py) | Connects to the nearest device and prints samples per second, gaps, mean µV per channel and battery. |
| [`examples/record_csv.py`](examples/record_csv.py) | Records EEG and accelerometer to `<out>_eeg.csv` and `<out>_mems.csv`. |
| [`examples/spectrum.py`](examples/spectrum.py) | Filters the EEG and prints each band's share per channel once per second. |

```sh
py -3 examples/stream.py --seconds 30
py -3 examples/record_csv.py --seconds 120 --gain 12 --out session1
py -3 examples/spectrum.py --mains 50
```

## API

### Module functions

| Function | Description |
|---|---|
| `await discover(timeout=5.0) -> list[Discovery]` | Every BlueLine seen, strongest first. |
| `await find(timeout=10.0, address=None) -> Discovery or None` | First BlueLine seen (or the one with `address`). |
| `async with scan(timeout=None, allow_duplicates=False) as devices: async for d in devices` | Live scanning; leaving the block stops the scan. |
| `await connect(target, timeout=20.0) -> BlueLineDevice` | `target`: a `Discovery`, a bleak `BLEDevice` or an address. Reads Info, serial and firmware, enables notifications. |

`Discovery`: `name`, `address`, `rssi`, `advertisement` (`model`,
`chip_id_low` to tell devices apart before connecting), `ble_device`.

### `BlueLineDevice`

| Member | Description |
|---|---|
| `info: Info` | `channel_count`, `signal_rate_hz` (250), `mems_rate_hz` (100), `gain`, `vref_microvolts`, `microvolts_per_count`, `firmware_version`, `features`, `chip_id` / `chip_id_hex`. |
| `serial_number`, `firmware_revision`, `battery_level`, `status`, `mtu`, `session`, `is_connected` | |
| `await start_signal() -> int` | Starts EEG; returns the session. Sample indices restart at 0. |
| `await stop_signal()`, `await start_mems()`, `await stop_mems()` | |
| `await set_gain(gain) -> int` | 1, 2, 4, 6, 8, 12 or 24 (6 after every boot). Restarts acquisition: new session. |
| `await identify()` | Blinks the LED green for 2 s. |
| `await disconnect()` | Sends STOP_SIGNAL, then disconnects. Also on leaving `async with`. |
| `on_signal`, `on_mems`, `on_status`, `on_battery_level`, `on_disconnect` | Callbacks, called on the event loop. Keep them short. |
| `signal_packets(maxsize=512)` | Async iterator of EEG packets; ends on disconnect. |

Commands run one at a time. Failures raise subclasses of
`blueline.BlueLineError`: `BluetoothUnavailable`, `ConnectionFailed`,
`UnsupportedDevice`, `Timeout`, `NotConnected`, `Disconnected`,
`InvalidParameter`, `CommandFailed` (with `.result`).

### Data types

`SignalPacket`: `session`, `first_index`, `samples` (raw counts,
`[sample][channel]`), `microvolts`, `gap_before`, `sample_count`,
`channel_count`, `to_numpy(microvolts=True)`.
`MemsSample`: `session`, `mems_index`, `signal_index`, `x`/`y`/`z`,
`x_g`/`y_g`/`z_g`. `Status`: `is_streaming`, `flags`, `battery_percent`,
`gain`, `mtu`, `session`, `signal_samples_dropped`, `adc_frames_lost`,
`mems_samples_dropped`.

The parsers in `blueline.protocol` and `SignalSessionTracker` need only the
standard library, so recorded notifications can be decoded without Bluetooth.

### Signal processing

```python
from blueline import SignalFilter, SpectrumAnalyzer

channels = device.info.channel_count
filt = SignalFilter(channels)                 # 0.5–40 Hz band-pass, 50 Hz notch
analyzer = SpectrumAnalyzer(channels)         # 4 s window, 5 updates per second

def on_signal(packet):
    filtered = filt.process(packet)           # [sample][channel] in µV
    for frame in analyzer.process(packet):    # usually none, sometimes one
        alpha = frame.channels[0].relative["alpha"]   # share of total, 0–1
```

| Member | Description |
|---|---|
| `SignalFilter(channel_count, sample_rate=250, highpass=0.5, lowpass=40, notch=50, order=4, filters=None)` | Same chain on every channel. `None` leaves a stage out; `filters` replaces the defaults. `process(packet)`, `filter_rows(rows)`, `reset()`. |
| `Filter.lowpass / highpass(sample_rate, cutoff, order=4)`, `Filter.bandpass(sample_rate, low, high, order=4)`, `Filter.notch(sample_rate, frequency=50, quality=30)` | Single-channel filters: `filter(x)`, `filter_array(values)`, `response(frequency, sample_rate)`. Chain them with `FilterList`. |
| `SpectrumAnalyzer(channel_count, sample_rate=250, window=4.0, update_rate=5.0, max_frequency=50, bands=EEG_BANDS, normalize_by_bandwidth=False)` | `process(packet) -> list[SpectrumFrame]`, `add_rows(rows)`, `fill`, `reset()`. |
| `SpectrumFrame` | `session`, `end_index`, `end_time(sample_rate)`, `frequencies`, `channels[c].psd` (µV²/Hz), `.powers` (µV²), `.relative`. |
| `processing.power_spectrum(values, sample_rate, nfft=None, max_frequency=None)`, `band_powers(freqs, psd, bands)`, `relative_powers(powers, bands, normalize_by_bandwidth)` | The same calculations on one window of recorded data. |

`SignalFilter` and `SpectrumAnalyzer` reset themselves on a new session or after
lost samples. Pure Python; NumPy, when installed, only speeds up the FFT.

The meaning of every field, sessions, gaps and units is described in the
[main README](../README.md#how-a-session-works) and
[docs/PROTOCOL.md](../docs/PROTOCOL.md).

## Platform notes

- **Windows**: works with the built-in Bluetooth of Windows 10/11. The
  device's `address` is its MAC address. Only one app can be connected to a
  device at a time: close the BlueLine Test Studio or a phone app first.
- **macOS**: `address` is a CoreBluetooth UUID, not the MAC address, and is
  different on every Mac. The terminal (or Python app) needs Bluetooth
  permission in System Settings > Privacy & Security.
- **Linux**: needs BlueZ 5.55+; the user may need to be in the `bluetooth` group.

## Tests

```sh
py -3 -m unittest discover -s tests -t .
```

(run with `PYTHONPATH=src` if the package is not installed). The tests need no
Bluetooth and no device:

| Test | Covers |
|---|---|
| `test_vectors.py` | The shared byte-level vectors in `../testvectors/` (same cases as iOS and Android). |
| `test_session.py` | Session and gap tracking (same cases as Android). |
| `test_device.py` | `BlueLineDevice` against a fake bleak client that behaves like the firmware: connection setup, old-firmware rejection, sessions, gain change, BUSY / NOT_SUPPORTED, timeouts, command ordering, disconnect and link loss, the packet iterator and its overflow. |
| `test_recording.py` | CSV output. |
| `test_processing.py` | Filters, spectrum and band powers: the shared vectors in `../testvectors/blueline_processing_v1.json`, filter responses, reset on gaps. |
