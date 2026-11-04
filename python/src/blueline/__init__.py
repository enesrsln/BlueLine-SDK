"""BlueLine SDK for Python: stream EEG and accelerometer data from BlueLine devices.

>>> import asyncio, blueline
>>> async def main():
...     found = await blueline.discover()
...     async with await blueline.connect(found[0]) as device:
...         device.on_signal = lambda packet: print(packet.first_index, packet.microvolts[0])
...         await device.start_signal()
...         await asyncio.sleep(10)
>>> asyncio.run(main())

The protocol types (``blueline.protocol``) need only the standard library; the
Bluetooth part (``scan``, ``discover``, ``connect``, ``BlueLineDevice``) needs bleak
and is imported on first use.
"""

from . import errors
from .errors import (
    BlueLineError,
    BluetoothUnavailable,
    CommandFailed,
    ConnectionFailed,
    Disconnected,
    InvalidParameter,
    NotConnected,
    Timeout,
    UnsupportedDevice,
)
from .protocol import (
    SUPPORTED_GAINS,
    Advertisement,
    Command,
    ControlResponse,
    Feature,
    Info,
    MemsSample,
    Result,
    SignalPacket,
    Status,
    StatusFlag,
)
from .session import SignalSessionTracker
from . import processing
from .processing import EEG_BANDS, Filter, FilterList, SignalFilter, SpectrumAnalyzer, SpectrumFrame

__version__ = "1.0.0"

_BLE_NAMES = {"scan", "discover", "find", "connect", "BlueLineDevice", "Discovery"}


def __getattr__(name):
    if name in _BLE_NAMES:
        from . import device

        return getattr(device, name)
    raise AttributeError(f"module 'blueline' has no attribute {name!r}")


__all__ = sorted(
    _BLE_NAMES
    | {
        "errors", "BlueLineError", "BluetoothUnavailable", "CommandFailed", "ConnectionFailed", "Disconnected",
        "InvalidParameter", "NotConnected", "Timeout", "UnsupportedDevice", "SUPPORTED_GAINS", "Advertisement",
        "Command", "ControlResponse", "Feature", "Info", "MemsSample", "Result", "SignalPacket", "Status",
        "StatusFlag", "SignalSessionTracker", "processing", "EEG_BANDS", "Filter", "FilterList",
        "SignalFilter", "SpectrumAnalyzer", "SpectrumFrame",
    }
)
