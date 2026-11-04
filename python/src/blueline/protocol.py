"""BlueLine BLE protocol v1: UUIDs and packet parsers.

Pure data types with no Bluetooth state, so they can also decode recorded
notifications. Multi-byte fields are little-endian, except EEG samples, which
are signed 24-bit big-endian (ADS1299 native). See docs/PROTOCOL.md.
"""

from __future__ import annotations

import enum
import struct
from dataclasses import dataclass, replace
from typing import Optional, Sequence, Tuple

PROTOCOL_VERSION = 1

_BASE = "8e7c{:04x}-7b4e-4c1e-af19-22a6f38d9b40"


def _sig(uuid16: int) -> str:
    return f"0000{uuid16:04x}-0000-1000-8000-00805f9b34fb"


SERVICE_UUID = _BASE.format(0x0001)
INFO_UUID = _BASE.format(0x0002)
SIGNAL_UUID = _BASE.format(0x0003)
MEMS_UUID = _BASE.format(0x0004)
STATUS_UUID = _BASE.format(0x0005)
CONTROL_UUID = _BASE.format(0x0006)

BATTERY_SERVICE_UUID = _sig(0x180F)
BATTERY_LEVEL_UUID = _sig(0x2A19)
DEVICE_INFORMATION_SERVICE_UUID = _sig(0x180A)
SERIAL_NUMBER_UUID = _sig(0x2A25)
FIRMWARE_REVISION_UUID = _sig(0x2A26)

#: Company id of the manufacturer data in the scan response.
COMPANY_ID = 0xFFFF

SIGNAL_HEADER_BYTES = 8
BYTES_PER_CHANNEL_SAMPLE = 3
_U32_MASK = 0xFFFF_FFFF


def _i24be(b: bytes, o: int) -> int:
    v = (b[o] << 16) | (b[o + 1] << 8) | b[o + 2]
    return v - (1 << 24) if v & 0x80_0000 else v


# ---------------------------------------------------------------- advertisement


@dataclass(frozen=True)
class Advertisement:
    """Manufacturer data in the scan response: ``'B' 'L' model(u8) chip_id_low(u32)``."""

    #: Model number, e.g. 4 = BlueLine-4.
    model: int
    #: Bits 0..31 of the chip id: tells devices apart before connecting.
    chip_id_low: int

    @classmethod
    def from_company_payload(cls, payload: Optional[bytes]) -> Optional["Advertisement"]:
        """Parses the bytes after the company id (bleak's ``manufacturer_data[0xFFFF]``)."""
        if payload is None or len(payload) < 7 or payload[0] != ord("B") or payload[1] != ord("L"):
            return None
        (chip_id_low,) = struct.unpack_from("<I", payload, 3)
        return cls(model=payload[2], chip_id_low=chip_id_low)

    @classmethod
    def from_manufacturer_data(cls, data: Optional[bytes]) -> Optional["Advertisement"]:
        """Parses full manufacturer data including the 2-byte company id."""
        if data is None or len(data) < 9 or struct.unpack_from("<H", data, 0)[0] != COMPANY_ID:
            return None
        return cls.from_company_payload(bytes(data[2:]))


# ---------------------------------------------------------------- info


class Feature(enum.IntFlag):
    """Capabilities from the Info ``features`` bitmask."""

    SIGNAL = 1 << 0
    MEMS = 1 << 1
    #: Impedance measurement (reserved; not implemented by firmware 0.3.x).
    RESIST = 1 << 2
    IDENTIFY = 1 << 3
    SET_GAIN = 1 << 4


@dataclass(frozen=True)
class Info:
    """Static device description read once after connecting (32 bytes)."""

    BYTE_COUNT = 32

    protocol_version: int
    model: int
    #: The Device Information serial number is a factory serial (otherwise the chip id).
    has_factory_serial: bool
    channel_count: int
    firmware_major: int
    firmware_minor: int
    firmware_patch: int
    adc_bits: int
    adc_rate_hz: int
    #: EEG output rate (250 Hz).
    signal_rate_hz: int
    #: ADC samples averaged per output sample (4).
    decimation: int
    #: Current PGA gain; ``BlueLineDevice.info`` follows ``set_gain``.
    gain: int
    vref_microvolts: int
    mems_rate_hz: int
    max_samples_per_packet: int
    signal_header_bytes: int
    feature_bits: int
    #: 64-bit chip id (FICR DEVICEID).
    chip_id: int

    @property
    def features(self) -> Feature:
        return Feature(self.feature_bits & sum(Feature))

    def supports(self, feature: Feature) -> bool:
        return bool(self.feature_bits & feature)

    @property
    def firmware_version(self) -> str:
        return f"{self.firmware_major}.{self.firmware_minor}.{self.firmware_patch}"

    @property
    def chip_id_hex(self) -> str:
        """16 uppercase hex characters, as the serial reports it without a factory serial."""
        return f"{self.chip_id:016X}"

    @property
    def microvolts_per_count(self) -> float:
        """uV = code * vref_uV / (gain * 2^23)"""
        return self.vref_microvolts / (self.gain * 8_388_608.0)

    @property
    def is_supported(self) -> bool:
        """Fields the decoder relies on match this SDK."""
        return (
            self.protocol_version == PROTOCOL_VERSION
            and self.signal_header_bytes == SIGNAL_HEADER_BYTES
            and self.supports(Feature.SIGNAL)
        )

    def with_gain(self, gain: int) -> "Info":
        return replace(self, gain=gain)

    @classmethod
    def parse(cls, data: Optional[bytes]) -> Optional["Info"]:
        """Returns None for short or malformed data (zero channels, rate, gain or reference)."""
        if data is None or len(data) < cls.BYTE_COUNT:
            return None
        d = bytes(data)
        adc_rate, signal_rate = struct.unpack_from("<HH", d, 8)
        (vref,) = struct.unpack_from("<I", d, 14)
        (mems_rate,) = struct.unpack_from("<H", d, 18)
        (features,) = struct.unpack_from("<H", d, 22)
        (chip_id,) = struct.unpack_from("<Q", d, 24)
        info = cls(
            protocol_version=d[0], model=d[1], has_factory_serial=bool(d[2] & 0x01), channel_count=d[3],
            firmware_major=d[4], firmware_minor=d[5], firmware_patch=d[6], adc_bits=d[7],
            adc_rate_hz=adc_rate, signal_rate_hz=signal_rate, decimation=d[12], gain=d[13],
            vref_microvolts=vref, mems_rate_hz=mems_rate, max_samples_per_packet=d[20],
            signal_header_bytes=d[21], feature_bits=features, chip_id=chip_id,
        )
        if info.channel_count <= 0 or info.signal_rate_hz <= 0 or info.gain <= 0 or info.vref_microvolts <= 0:
            return None
        return info


# ---------------------------------------------------------------- signal


@dataclass(frozen=True)
class SignalPacket:
    """One EEG notification: up to 19 consecutive samples of every channel.

    Sample ``i`` has index ``first_index + i`` and time ``index / signal_rate_hz``
    seconds since START_SIGNAL of its ``session``.
    """

    #: Samples before ``first_index`` were lost (on the device, over BLE, or because
    #: the app did not consume packets fast enough). Do not interpolate silently.
    gap_before: bool
    session: int
    #: Sample index of the first sample since START_SIGNAL (unsigned 32-bit).
    first_index: int
    #: Raw signed 24-bit ADC counts as ``[sample][channel]``.
    samples: Tuple[Tuple[int, ...], ...]
    #: Scale of this packet's session; 0 if unknown (parsed without a tracker).
    microvolts_per_count: float = 0.0

    @property
    def sample_count(self) -> int:
        return len(self.samples)

    @property
    def channel_count(self) -> int:
        return len(self.samples[0]) if self.samples else 0

    @property
    def next_index(self) -> int:
        """Index of the sample after this packet (wraps at 2^32)."""
        return (self.first_index + len(self.samples)) & _U32_MASK

    @property
    def microvolts(self) -> Tuple[Tuple[float, ...], ...]:
        """Samples in microvolts as ``[sample][channel]``."""
        k = self.microvolts_per_count
        return tuple(tuple(v * k for v in row) for row in self.samples)

    def to_numpy(self, microvolts: bool = True):
        """``(samples, channels)`` array; float64 microvolts, or int32 counts. Needs numpy."""
        import numpy as np

        counts = np.asarray(self.samples, dtype=np.int32).reshape(len(self.samples), -1)
        return counts * self.microvolts_per_count if microvolts else counts

    @classmethod
    def parse(cls, data: Optional[bytes], channel_count: int) -> Optional["SignalPacket"]:
        """Returns None unless the length is exactly ``8 + count * channel_count * 3``."""
        header = SIGNAL_HEADER_BYTES
        if data is None or channel_count <= 0 or len(data) <= header:
            return None
        d = bytes(data)
        count = d[1]
        stride = channel_count * BYTES_PER_CHANNEL_SAMPLE
        if count <= 0 or len(d) != header + count * stride:
            return None
        session, first = struct.unpack_from("<HI", d, 2)
        samples = tuple(
            tuple(_i24be(d, header + s * stride + c * BYTES_PER_CHANNEL_SAMPLE) for c in range(channel_count))
            for s in range(count)
        )
        return cls(gap_before=bool(d[0] & 0x01), session=session, first_index=first, samples=samples)


# ---------------------------------------------------------------- mems


@dataclass(frozen=True)
class MemsSample:
    """One accelerometer sample (ADXL345, 100 Hz, raw counts, gravity included). 16 bytes."""

    BYTE_COUNT = 16
    #: ADXL345 full resolution: 3.9 mg per count.
    G_PER_COUNT = 0.0039

    session: int
    mems_index: int
    #: EEG sample index when this sample was read; None while the signal is stopped.
    #: Approximate alignment, not a hardware-synchronized timestamp.
    signal_index: Optional[int]
    x: int
    y: int
    z: int

    @property
    def x_g(self) -> float:
        return self.x * self.G_PER_COUNT

    @property
    def y_g(self) -> float:
        return self.y * self.G_PER_COUNT

    @property
    def z_g(self) -> float:
        return self.z * self.G_PER_COUNT

    @classmethod
    def parse(cls, data: Optional[bytes]) -> Optional["MemsSample"]:
        if data is None or len(data) < cls.BYTE_COUNT:
            return None
        session, mems_index, signal_index, x, y, z = struct.unpack_from("<HIIhhh", bytes(data), 0)
        return cls(session, mems_index, None if signal_index == _U32_MASK else signal_index, x, y, z)


# ---------------------------------------------------------------- status


class StatusFlag(enum.IntFlag):
    MEMS_ON = 1 << 0
    #: The BLE TX queue was full; signal samples are being dropped.
    TX_BLOCKED = 1 << 1
    ADS_FAULT = 1 << 2
    ADXL_FAULT = 1 << 3


@dataclass(frozen=True)
class Status:
    """Device state and per-session loss counters (20 bytes). State, flag and gain
    changes notify immediately; counter-only changes at most once per second."""

    BYTE_COUNT = 20

    is_streaming: bool
    flag_bits: int
    battery_percent: int
    gain: int
    #: Effective ATT MTU.
    mtu: int
    session: int
    #: Samples dropped because the BLE queue was full, this session.
    signal_samples_dropped: int
    #: ADC frames lost before processing, this session.
    adc_frames_lost: int
    mems_samples_dropped: int

    @property
    def flags(self) -> StatusFlag:
        return StatusFlag(self.flag_bits & sum(StatusFlag))

    def has(self, flag: StatusFlag) -> bool:
        return bool(self.flag_bits & flag)

    @classmethod
    def parse(cls, data: Optional[bytes]) -> Optional["Status"]:
        if data is None or len(data) < cls.BYTE_COUNT:
            return None
        d = bytes(data)
        mtu, session = struct.unpack_from("<HH", d, 4)
        dropped, lost, mems_dropped = struct.unpack_from("<III", d, 8)
        return cls(d[0] == 1, d[1], d[2], d[3], mtu, session, dropped, lost, mems_dropped)


# ---------------------------------------------------------------- control


class Command(enum.IntEnum):
    """Control opcodes."""

    START_SIGNAL = 0x01
    STOP_SIGNAL = 0x02
    START_MEMS = 0x03
    STOP_MEMS = 0x04
    START_RESIST = 0x05
    STOP_RESIST = 0x06
    SET_GAIN = 0x10
    IDENTIFY = 0x20

    def request(self, *params: int) -> bytes:
        """Request bytes: ``[opcode] [params...]``."""
        return bytes([int(self), *params])


#: Answer to a request written while the previous one was still running.
BUSY_OPCODE = 0xFF
#: Gains accepted by SET_GAIN. The device boots with 6.
SUPPORTED_GAINS: Sequence[int] = (1, 2, 4, 6, 8, 12, 24)


class Result(enum.IntEnum):
    """Control result codes."""

    OK = 0
    NOT_SUPPORTED = 1
    INVALID_PARAM = 2
    INVALID_STATE = 3
    BUSY = 4
    HARDWARE_FAULT = 5


@dataclass(frozen=True)
class ControlResponse:
    """Control notification: ``[opcode] [result] [payload...]``."""

    opcode: int
    raw_result: int
    payload: bytes

    @property
    def result(self) -> Optional[Result]:
        try:
            return Result(self.raw_result)
        except ValueError:
            return None

    @property
    def is_ok(self) -> bool:
        return self.raw_result == Result.OK

    @property
    def session(self) -> Optional[int]:
        """START_SIGNAL: session u16. SET_GAIN: gain u8, session u16. None otherwise."""
        offsets = {Command.START_SIGNAL: 0, Command.SET_GAIN: 1}
        offset = offsets.get(self.opcode)  # IntEnum keys compare equal to ints
        if offset is None or len(self.payload) < offset + 2:
            return None
        return struct.unpack_from("<H", self.payload, offset)[0]

    def answers(self, command: Command) -> bool:
        """True if this answers ``command`` (or is the BUSY answer to any request)."""
        return self.opcode in (int(command), BUSY_OPCODE)

    @classmethod
    def parse(cls, data: Optional[bytes]) -> Optional["ControlResponse"]:
        if data is None or len(data) < 2:
            return None
        d = bytes(data)
        return cls(opcode=d[0], raw_result=d[1], payload=d[2:])
