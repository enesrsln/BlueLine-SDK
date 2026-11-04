"""Scanning and connected devices, on asyncio + bleak (Windows, macOS, Linux)."""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass, replace
from typing import AsyncIterator, Callable, List, Optional, Union

from bleak import BleakClient, BleakScanner
from bleak.backends.device import BLEDevice
from bleak.backends.scanner import AdvertisementData
from bleak.exc import BleakError

from . import errors
from .protocol import (
    BATTERY_LEVEL_UUID,
    COMPANY_ID,
    CONTROL_UUID,
    FIRMWARE_REVISION_UUID,
    INFO_UUID,
    MEMS_UUID,
    SERIAL_NUMBER_UUID,
    SERVICE_UUID,
    SIGNAL_UUID,
    STATUS_UUID,
    SUPPORTED_GAINS,
    Advertisement,
    Command,
    ControlResponse,
    Feature,
    Info,
    MemsSample,
    SignalPacket,
    Status,
)
from .session import SignalSessionTracker

log = logging.getLogger("blueline")

#: Signal packets buffered per ``signal_packets()`` iterator (~10 s at 50 packets/s).
SIGNAL_QUEUE_SIZE = 512


@dataclass(frozen=True)
class Discovery:
    """A BlueLine device seen while scanning."""

    ble_device: BLEDevice
    #: MAC address (Windows, Linux) or CoreBluetooth UUID (macOS).
    address: str
    name: str
    rssi: int
    #: Model and chip id from the scan response, when present.
    advertisement: Optional[Advertisement]


def _as_discovery(device: BLEDevice, adv: AdvertisementData) -> Optional[Discovery]:
    advertisement = Advertisement.from_company_payload(adv.manufacturer_data.get(COMPANY_ID))
    has_service = SERVICE_UUID in (u.lower() for u in adv.service_uuids)
    if not has_service and advertisement is None:
        return None
    return Discovery(
        ble_device=device,
        address=device.address,
        name=adv.local_name or device.name or "BlueLine",
        rssi=adv.rssi,
        advertisement=advertisement,
    )


class scan:
    """Scans for BlueLine devices; an async context manager and async iterator.

    ::

        async with blueline.scan(timeout=10) as devices:
            async for found in devices:
                print(found.name, found.rssi)
                if found.advertisement and found.advertisement.chip_id_low == wanted:
                    break

    Iteration ends after ``timeout`` seconds (never if None). Each device is
    yielded once, or on every advertisement with ``allow_duplicates`` (live RSSI).
    Leaving the ``async with`` block stops scanning, also after ``break``.
    """

    def __init__(self, timeout: Optional[float] = None, allow_duplicates: bool = False):
        self._timeout = timeout
        self._allow_duplicates = allow_duplicates
        self._queue: "asyncio.Queue[Discovery]" = asyncio.Queue()
        self._seen: set = set()
        self._scanner: Optional[BleakScanner] = None
        self._deadline: Optional[float] = None

    def _on_advertisement(self, device: BLEDevice, adv: AdvertisementData) -> None:
        found = _as_discovery(device, adv)
        if found is None or (not self._allow_duplicates and found.address in self._seen):
            return
        self._seen.add(found.address)
        self._queue.put_nowait(found)

    async def start(self) -> None:
        if self._scanner is not None:
            return
        # No service filter: on Windows the service UUID is only in the scan response,
        # which a WinRT filter can miss. Filtering happens in the callback.
        self._scanner = BleakScanner(detection_callback=self._on_advertisement, scanning_mode="active")
        try:
            await self._scanner.start()
        except (BleakError, OSError) as e:
            self._scanner = None
            raise errors.BluetoothUnavailable(str(e)) from e
        if self._timeout is not None:
            self._deadline = asyncio.get_running_loop().time() + self._timeout

    async def stop(self) -> None:
        scanner, self._scanner = self._scanner, None
        if scanner is not None:
            try:
                await scanner.stop()
            except (BleakError, OSError):
                pass

    async def __aenter__(self) -> "scan":
        await self.start()
        return self

    async def __aexit__(self, *exc) -> None:
        await self.stop()

    def __aiter__(self) -> "scan":
        return self

    async def __anext__(self) -> Discovery:
        if self._scanner is None:
            if self._deadline is not None:  # already timed out and stopped
                raise StopAsyncIteration
            await self.start()
        remaining = None
        if self._deadline is not None:
            remaining = self._deadline - asyncio.get_running_loop().time()
        if remaining is not None and remaining <= 0:
            await self.stop()
            raise StopAsyncIteration
        try:
            return await asyncio.wait_for(self._queue.get(), remaining)
        except asyncio.TimeoutError:
            await self.stop()
            raise StopAsyncIteration from None


async def discover(timeout: float = 5.0) -> List[Discovery]:
    """Scans for ``timeout`` seconds and returns every BlueLine found, strongest signal first."""
    async with scan(timeout=timeout) as devices:
        found = [d async for d in devices]
    return sorted(found, key=lambda d: d.rssi, reverse=True)


async def find(timeout: float = 10.0, address: Optional[str] = None) -> Optional[Discovery]:
    """Returns the first BlueLine seen (or the one with ``address``), or None after ``timeout``."""
    async with scan(timeout=timeout) as devices:
        async for found in devices:
            if address is None or found.address.lower() == address.lower():
                return found
    return None


async def connect(target: Union[Discovery, BLEDevice, str], timeout: float = 20.0) -> "BlueLineDevice":
    """Connects, reads Info and the device information, and enables notifications.

    ``target`` is a :class:`Discovery`, a bleak ``BLEDevice`` or an address. The
    returned device is ready for ``start_signal()``. Use it as an async context
    manager to disconnect automatically.
    """
    if isinstance(target, Discovery):
        ble, name = target.ble_device, target.name
    elif isinstance(target, BLEDevice):
        ble, name = target, target.name or "BlueLine"
    else:
        found = await BleakScanner.find_device_by_address(target, timeout=min(timeout, 10.0))
        if found is None:
            raise errors.ConnectionFailed(f"no device with address {target} is advertising")
        ble, name = found, found.name or "BlueLine"
    device = BlueLineDevice(ble, name)
    try:
        await asyncio.wait_for(device._establish(timeout), timeout)
    except asyncio.TimeoutError:
        await device._abort()
        raise errors.Timeout("connect") from None
    except BaseException:
        await device._abort()
        raise
    return device


class BlueLineDevice:
    """A connected BlueLine device, obtained from :func:`connect`.

    Commands are coroutines and run one at a time (the firmware rejects
    overlapping requests). Failures raise :class:`~blueline.errors.BlueLineError`.
    Data arrives through the ``on_*`` callbacks (called on the event loop) and
    through :meth:`signal_packets`.
    """

    def __init__(self, ble_device: BLEDevice, name: str):
        self.ble_device = ble_device
        self.name = name
        self.address: str = ble_device.address
        self._client: Optional[BleakClient] = None
        self._info: Optional[Info] = None
        self._tracker: Optional[SignalSessionTracker] = None
        self._connected = False
        self._user_disconnect = False
        self._control_lock = asyncio.Lock()
        self._pending: Optional[tuple] = None  # (Command, Future[ControlResponse])
        self._queues: List[list] = []  # [queue, pending_gap]

        self.serial_number: Optional[str] = None
        self.firmware_revision: Optional[str] = None
        self.battery_level: Optional[int] = None
        self.status: Optional[Status] = None

        #: EEG packets of the current session (about every 20 ms, 5 samples at 250 Hz).
        self.on_signal: Optional[Callable[[SignalPacket], None]] = None
        #: Accelerometer samples (100 Hz) after ``start_mems()``.
        self.on_mems: Optional[Callable[[MemsSample], None]] = None
        #: State, gain and loss counters.
        self.on_status: Optional[Callable[[Status], None]] = None
        self.on_battery_level: Optional[Callable[[int], None]] = None
        #: The connection closed; the argument is None after ``disconnect()``.
        self.on_disconnect: Optional[Callable[[Optional[errors.BlueLineError]], None]] = None

    # ------------------------------------------------------------ properties

    @property
    def info(self) -> Info:
        """Read during connection; ``gain`` follows :meth:`set_gain`."""
        if self._info is None:
            raise errors.NotConnected()
        return self._info

    @property
    def is_connected(self) -> bool:
        return self._connected

    @property
    def session(self) -> Optional[int]:
        """Session of the running acquisition; None while the signal is stopped."""
        return self._tracker.active_session if self._tracker else None

    @property
    def mtu(self) -> Optional[int]:
        return self._client.mtu_size if self._client else None

    # ------------------------------------------------------------ commands

    async def start_signal(self) -> int:
        """Starts EEG acquisition and returns the session. If already streaming the
        device keeps the current session and returns it. Sample indices restart at 0."""
        response = await self._send(Command.START_SIGNAL)
        if response.session is None:
            raise errors.CommandFailed(Command.START_SIGNAL, response.result, response.raw_result)
        return response.session

    async def stop_signal(self) -> None:
        await self._send(Command.STOP_SIGNAL)

    async def start_mems(self) -> None:
        """Starts the accelerometer stream (``on_mems``)."""
        self._require(Feature.MEMS)
        await self._send(Command.START_MEMS)

    async def stop_mems(self) -> None:
        await self._send(Command.STOP_MEMS)

    async def set_gain(self, gain: int) -> int:
        """Sets the PGA gain (1, 2, 4, 6, 8, 12 or 24; 6 after every boot).

        While streaming this restarts acquisition: a new session starts and the
        sample index restarts at 0. Never mix samples of different sessions.
        Returns the session.
        """
        if gain not in SUPPORTED_GAINS:
            raise errors.InvalidParameter(f"gain {gain} not in {list(SUPPORTED_GAINS)}")
        self._require(Feature.SET_GAIN)
        response = await self._send(Command.SET_GAIN, gain)
        if response.session is None:
            raise errors.CommandFailed(Command.SET_GAIN, response.result, response.raw_result)
        return response.session

    async def identify(self) -> None:
        """Blinks the device LED green for 2 seconds."""
        self._require(Feature.IDENTIFY)
        await self._send(Command.IDENTIFY)

    async def disconnect(self) -> None:
        """Stops acquisition (STOP_SIGNAL) and closes the connection."""
        if self._client is None:
            return
        if self._connected and self.session is not None:
            try:
                await self._send(Command.STOP_SIGNAL, timeout=1.0)
            except errors.BlueLineError:
                pass  # disconnecting stops acquisition on the device anyway
        self._user_disconnect = True
        client = self._client
        try:
            await client.disconnect()
        except (BleakError, OSError):
            pass
        self._handle_disconnect(None)

    async def __aenter__(self) -> "BlueLineDevice":
        return self

    async def __aexit__(self, *exc) -> None:
        await self.disconnect()

    # ------------------------------------------------------------ async iteration

    async def signal_packets(self, maxsize: int = SIGNAL_QUEUE_SIZE) -> AsyncIterator[SignalPacket]:
        """Yields EEG packets until the device disconnects.

        Start iterating before ``start_signal()``. If the consumer falls ``maxsize``
        packets behind, packets are dropped and the next one has ``gap_before=True``.
        """
        entry = [asyncio.Queue(maxsize=maxsize), False]
        self._queues.append(entry)
        try:
            while True:
                packet = await entry[0].get()
                if packet is None:  # disconnected
                    return
                yield packet
        finally:
            self._queues.remove(entry)

    # ------------------------------------------------------------ internals

    def _require(self, feature: Feature) -> None:
        if not self.info.supports(feature):
            raise errors.UnsupportedDevice(
                f"feature {feature.name} not supported by firmware {self.info.firmware_version}"
            )

    async def _send(self, command: Command, *params: int, timeout: float = 3.0) -> ControlResponse:
        async with self._control_lock:
            if not self._connected or self._client is None:
                raise errors.NotConnected()
            future: "asyncio.Future[ControlResponse]" = asyncio.get_running_loop().create_future()
            self._pending = (command, future)
            try:
                try:
                    await self._client.write_gatt_char(CONTROL_UUID, command.request(*params), response=True)
                except (BleakError, OSError) as e:
                    raise errors.ConnectionFailed(f"writing {command.name}: {e}") from e
                try:
                    response = await asyncio.wait_for(future, timeout)
                except asyncio.TimeoutError:
                    raise errors.Timeout(command.name) from None
            finally:
                self._pending = None
            if not response.is_ok:
                raise errors.CommandFailed(command, response.result, response.raw_result)
            return response

    async def _establish(self, timeout: float) -> None:
        self._client = BleakClient(
            self.ble_device,
            disconnected_callback=lambda _client: self._handle_disconnect(errors.Disconnected()),
            timeout=timeout,
            winrt={"use_cached_services": False},
        )
        try:
            await self._client.connect()
        except (BleakError, OSError) as e:
            raise errors.ConnectionFailed(str(e)) from e
        self._connected = True

        client = self._client
        if client.services.get_service(SERVICE_UUID) is None:
            raise errors.UnsupportedDevice("no BlueLine v1 service (firmware < 0.3.0?)")
        info = Info.parse(bytes(await self._read(INFO_UUID)))
        if info is None:
            raise errors.UnsupportedDevice("unreadable Info")
        if not info.is_supported:
            raise errors.UnsupportedDevice(f"protocol {info.protocol_version}, firmware {info.firmware_version}")
        self._info = info
        self._tracker = SignalSessionTracker(info.channel_count)

        self.serial_number = await self._read_text(SERIAL_NUMBER_UUID)
        self.firmware_revision = await self._read_text(FIRMWARE_REVISION_UUID)

        await self._notify(CONTROL_UUID, self._on_control)
        await self._notify(STATUS_UUID, self._on_status)
        await self._notify(SIGNAL_UUID, self._on_signal)
        if info.supports(Feature.MEMS):
            await self._notify(MEMS_UUID, self._on_mems)
        self.status = Status.parse(bytes(await self._read(STATUS_UUID)))

        if client.services.get_characteristic(BATTERY_LEVEL_UUID) is not None:
            try:
                level = await self._read(BATTERY_LEVEL_UUID)
                self.battery_level = level[0] if level else None
                await self._notify(BATTERY_LEVEL_UUID, self._on_battery)
            except errors.ConnectionFailed:
                pass  # optional; Status also reports the battery

    async def _read(self, uuid: str) -> bytearray:
        try:
            return await self._client.read_gatt_char(uuid)
        except (BleakError, OSError) as e:
            raise errors.ConnectionFailed(f"reading {uuid}: {e}") from e

    async def _read_text(self, uuid: str) -> Optional[str]:
        if self._client.services.get_characteristic(uuid) is None:
            return None
        try:
            return bytes(await self._read(uuid)).decode("utf-8", "replace").rstrip("\x00")
        except errors.ConnectionFailed:
            return None

    async def _notify(self, uuid: str, handler) -> None:
        try:
            await self._client.start_notify(uuid, lambda _char, data: handler(bytes(data)))
        except (BleakError, OSError) as e:
            raise errors.ConnectionFailed(f"enabling notifications on {uuid}: {e}") from e

    async def _abort(self) -> None:
        self._user_disconnect = True
        if self._client is not None:
            try:
                await self._client.disconnect()
            except (BleakError, OSError):
                pass
        self._handle_disconnect(None)

    def _handle_disconnect(self, error: Optional[errors.BlueLineError]) -> None:
        if self._client is None:
            return
        was_connected = self._connected
        self._client = None
        self._connected = False
        if self._tracker:
            self._tracker.end()
        if self._pending and not self._pending[1].done():
            self._pending[1].set_exception(errors.Disconnected())
        for queue, _gap in self._queues:
            _put_end(queue)
        if was_connected and self.on_disconnect:
            self.on_disconnect(None if self._user_disconnect else error)

    # ------------------------------------------------------------ notifications

    def _on_signal(self, data: bytes) -> None:
        tracker = self._tracker
        packet = tracker.accept(data) if tracker else None
        if packet is None:
            return
        if self.on_signal:
            self.on_signal(packet)
        for entry in self._queues:
            queue, pending_gap = entry
            out = replace(packet, gap_before=True) if pending_gap and not packet.gap_before else packet
            try:
                queue.put_nowait(out)
                entry[1] = False
            except asyncio.QueueFull:
                entry[1] = True

    def _on_mems(self, data: bytes) -> None:
        sample = MemsSample.parse(data)
        if sample is None:
            return
        active = self.session
        if (active is None or sample.session == active) and self.on_mems:
            self.on_mems(sample)

    def _on_control(self, data: bytes) -> None:
        response = ControlResponse.parse(data)
        pending = self._pending
        if response is None or pending is None or not response.answers(pending[0]):
            return
        command, future = pending
        self._on_control_response(command, response)
        if not future.done():
            future.set_result(response)

    def _on_control_response(self, command: Command, response: ControlResponse) -> None:
        """Runs in the notification handler, before the caller resumes, so no packet
        of a new session is dropped in between."""
        tracker = self._tracker
        if not response.is_ok or tracker is None:
            return
        if command == Command.START_SIGNAL and response.session is not None:
            tracker.begin(response.session, self.info.microvolts_per_count)
        elif command == Command.STOP_SIGNAL:
            tracker.end()
        elif command == Command.SET_GAIN:
            if response.payload and response.payload[0] > 0:
                self._info = self.info.with_gain(response.payload[0])
            if tracker.active_session is not None and response.session is not None:
                tracker.begin(response.session, self.info.microvolts_per_count)

    def _on_status(self, data: bytes) -> None:
        status = Status.parse(data)
        if status is None:
            return
        self.status = status
        if self.on_status:
            self.on_status(status)

    def _on_battery(self, data: bytes) -> None:
        if not data:
            return
        self.battery_level = data[0]
        if self.on_battery_level:
            self.on_battery_level(data[0])


def _put_end(queue: asyncio.Queue) -> None:
    """Wakes a ``signal_packets()`` iterator so it ends, even if its queue is full."""
    while True:
        try:
            queue.put_nowait(None)
            return
        except asyncio.QueueFull:
            queue.get_nowait()
