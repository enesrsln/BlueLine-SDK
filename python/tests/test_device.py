"""BlueLineDevice against a fake bleak client that behaves like BlueLine-4 firmware.

No Bluetooth needed. Covers connection setup, the control channel, sessions,
gain changes, disconnects and the async packet iterator.
"""

import asyncio
import struct
import unittest
from unittest import mock

from bleak.backends.device import BLEDevice

import blueline
from blueline import device as device_module
from blueline import errors
from blueline.protocol import (
    BATTERY_LEVEL_UUID,
    CONTROL_UUID,
    FIRMWARE_REVISION_UUID,
    INFO_UUID,
    MEMS_UUID,
    SERIAL_NUMBER_UUID,
    SERVICE_UUID,
    SIGNAL_UUID,
    STATUS_UUID,
    Command,
    Result,
)

INFO_HEX = "0104010400030118E803FA000406A0252600640013081B00EFCDAB8967452301"  # protocol 1, gain 6, 4 ch


def signal_bytes(session, first_index, count=5, channels=4):
    return struct.pack("<BBHI", 0, count, session, first_index) + b"\x00\x00\x01" * (count * channels)


def status_bytes(streaming=False, gain=6, session=0):
    return struct.pack("<BBBBHHIII", 1 if streaming else 0, 0, 80, gain, 247, session, 0, 0, 0)


class FakeServices:
    def __init__(self, uuids):
        self.uuids = set(uuids)

    def get_service(self, uuid):
        return object() if uuid in self.uuids else None

    def get_characteristic(self, uuid):
        return object() if uuid in self.uuids else None


class FakeFirmware:
    """Configurable behaviour shared by the fake client."""

    def __init__(self):
        self.info = bytes.fromhex(INFO_HEX)
        self.session = 0
        self.gain = 6
        self.streaming = False
        self.answer = True       # answer control requests
        self.busy = False        # answer with opcode 0xFF / BUSY
        self.writes = []
        self.client = None
        self.signal_after_start = 0  # packets to send right after START_SIGNAL's answer


class FakeClient:
    firmware: FakeFirmware = None

    def __init__(self, ble_device, disconnected_callback=None, timeout=30, **kwargs):
        self.fw = FakeClient.firmware
        self.fw.client = self
        self.disconnected_callback = disconnected_callback
        self.handlers = {}
        self.services = FakeServices([SERVICE_UUID, INFO_UUID, SIGNAL_UUID, MEMS_UUID, STATUS_UUID, CONTROL_UUID,
                                      SERIAL_NUMBER_UUID, FIRMWARE_REVISION_UUID, BATTERY_LEVEL_UUID])
        self.mtu_size = 247
        self.connected = False

    async def connect(self):
        self.connected = True

    async def disconnect(self):
        if self.connected:
            self.connected = False
            if self.disconnected_callback:
                self.disconnected_callback(self)

    async def read_gatt_char(self, uuid):
        return bytearray({
            INFO_UUID: self.fw.info,
            STATUS_UUID: status_bytes(self.fw.streaming, self.fw.gain, self.fw.session),
            SERIAL_NUMBER_UUID: b"BL4-000042",
            FIRMWARE_REVISION_UUID: b"0.3.1",
            BATTERY_LEVEL_UUID: b"\x57",
        }[uuid])

    async def start_notify(self, uuid, callback):
        self.handlers[uuid] = callback

    def notify(self, uuid, data):
        self.handlers[uuid](None, bytearray(data))

    async def write_gatt_char(self, uuid, data, response=True):
        assert uuid == CONTROL_UUID
        self.fw.writes.append(bytes(data))
        if not self.fw.answer:
            return
        loop = asyncio.get_running_loop()
        op = data[0]
        if self.fw.busy:
            loop.call_soon(self.notify, CONTROL_UUID, bytes([0xFF, Result.BUSY]))
            return
        payload = b""
        if op == Command.START_SIGNAL:
            if not self.fw.streaming:
                self.fw.session += 1
                self.fw.streaming = True
            payload = struct.pack("<H", self.fw.session)
        elif op == Command.STOP_SIGNAL:
            self.fw.streaming = False
        elif op == Command.SET_GAIN:
            self.fw.gain = data[1]
            if self.fw.streaming:
                self.fw.session += 1
            payload = bytes([self.fw.gain]) + struct.pack("<H", self.fw.session)
        elif op == Command.START_RESIST:
            loop.call_soon(self.notify, CONTROL_UUID, bytes([op, Result.NOT_SUPPORTED]))
            return
        loop.call_soon(self.notify, CONTROL_UUID, bytes([op, Result.OK]) + payload)
        if op == Command.START_SIGNAL:
            for i in range(self.fw.signal_after_start):
                loop.call_soon(self.notify, SIGNAL_UUID, signal_bytes(self.fw.session, 5 * i))

    # test helpers
    def send_signal(self, first_index, session=None, count=5):
        self.notify(SIGNAL_UUID, signal_bytes(self.fw.session if session is None else session, first_index, count))

    def drop_link(self):
        self.connected = False
        self.disconnected_callback(self)


class DeviceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.fw = FakeFirmware()
        FakeClient.firmware = self.fw
        patcher = mock.patch.object(device_module, "BleakClient", FakeClient)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.ble = BLEDevice("AA:BB:CC:DD:EE:FF", "BlueLine-4", None)

    async def connect(self):
        return await blueline.connect(self.ble, timeout=2)

    async def test_connect_reads_device_description(self):
        dev = await self.connect()
        self.assertTrue(dev.is_connected)
        self.assertEqual(dev.info.channel_count, 4)
        self.assertEqual(dev.info.firmware_version, "0.3.1")
        self.assertEqual(dev.serial_number, "BL4-000042")
        self.assertEqual(dev.firmware_revision, "0.3.1")
        self.assertEqual(dev.battery_level, 0x57)
        self.assertFalse(dev.status.is_streaming)
        self.assertEqual(set(self.fw.client.handlers),
                         {CONTROL_UUID, STATUS_UUID, SIGNAL_UUID, MEMS_UUID, BATTERY_LEVEL_UUID})

    async def test_old_firmware_is_rejected(self):
        self.fw.info = bytes([2]) + self.fw.info[1:]
        with self.assertRaises(errors.UnsupportedDevice):
            await self.connect()

    async def test_signal_of_current_session_only_with_scale(self):
        dev = await self.connect()
        received = []
        dev.on_signal = received.append
        self.fw.client.send_signal(0, session=1)  # before start: dropped
        session = await dev.start_signal()
        self.assertEqual(session, 1)
        self.fw.client.send_signal(0)
        self.fw.client.send_signal(5, session=99)  # other session: dropped
        self.fw.client.send_signal(5)
        self.assertEqual([p.first_index for p in received], [0, 5])
        self.assertAlmostEqual(received[0].microvolts_per_count, dev.info.microvolts_per_count)
        self.assertAlmostEqual(received[0].microvolts[0][0], 1 * dev.info.microvolts_per_count)

    async def test_first_packet_after_start_is_not_lost(self):
        self.fw.signal_after_start = 2
        dev = await self.connect()
        received = []
        dev.on_signal = received.append
        await dev.start_signal()
        await asyncio.sleep(0)
        self.assertEqual([p.first_index for p in received], [0, 5])

    async def test_gap_is_marked(self):
        dev = await self.connect()
        received = []
        dev.on_signal = received.append
        await dev.start_signal()
        for first in (0, 5, 15):
            self.fw.client.send_signal(first)
        self.assertEqual([p.gap_before for p in received], [False, False, True])

    async def test_set_gain_starts_new_session_and_rescales(self):
        dev = await self.connect()
        received = []
        dev.on_signal = received.append
        first = await dev.start_signal()
        scale6 = dev.info.microvolts_per_count
        second = await dev.set_gain(12)
        self.assertEqual(second, first + 1)
        self.assertEqual(dev.session, second)
        self.assertEqual(dev.info.gain, 12)
        self.fw.client.send_signal(100, session=first)  # old session: dropped
        self.fw.client.send_signal(0)
        self.assertEqual(len(received), 1)
        self.assertAlmostEqual(received[0].microvolts_per_count, scale6 / 2)

    async def test_set_gain_validates(self):
        dev = await self.connect()
        with self.assertRaises(errors.InvalidParameter):
            await dev.set_gain(5)
        self.assertEqual(self.fw.writes, [])

    async def test_busy_and_not_supported(self):
        dev = await self.connect()
        with self.assertRaises(errors.CommandFailed) as caught:
            await dev._send(Command.START_RESIST)
        self.assertEqual(caught.exception.result, Result.NOT_SUPPORTED)
        self.fw.busy = True
        with self.assertRaises(errors.CommandFailed) as caught:
            await dev.start_signal()
        self.assertEqual(caught.exception.result, Result.BUSY)

    async def test_timeout(self):
        dev = await self.connect()
        self.fw.answer = False
        with self.assertRaises(errors.Timeout):
            await dev._send(Command.IDENTIFY, timeout=0.05)

    async def test_commands_run_one_at_a_time(self):
        dev = await self.connect()
        await asyncio.gather(dev.start_signal(), dev.start_mems(), dev.identify())
        self.assertEqual([w[0] for w in self.fw.writes], [Command.START_SIGNAL, Command.START_MEMS, Command.IDENTIFY])

    async def test_disconnect_stops_signal_first(self):
        dev = await self.connect()
        reasons = []
        dev.on_disconnect = reasons.append
        await dev.start_signal()
        await dev.disconnect()
        self.assertEqual(self.fw.writes[-1], bytes([Command.STOP_SIGNAL]))
        self.assertFalse(dev.is_connected)
        self.assertEqual(reasons, [None])
        with self.assertRaises(errors.NotConnected):
            await dev.start_signal()

    async def test_context_manager_disconnects(self):
        async with await self.connect() as dev:
            await dev.start_signal()
        self.assertFalse(self.fw.client.connected)

    async def test_link_loss_fails_pending_command_and_reports(self):
        dev = await self.connect()
        reasons = []
        dev.on_disconnect = reasons.append
        self.fw.answer = False
        task = asyncio.create_task(dev._send(Command.IDENTIFY, timeout=5))
        await asyncio.sleep(0.01)
        self.fw.client.drop_link()
        with self.assertRaises(errors.Disconnected):
            await task
        self.assertEqual(len(reasons), 1)
        self.assertIsInstance(reasons[0], errors.Disconnected)

    async def test_signal_packets_iterator_and_overflow(self):
        dev = await self.connect()
        await dev.start_signal()
        iterator = dev.signal_packets(maxsize=2).__aiter__()
        pending = asyncio.ensure_future(iterator.__anext__())  # registers the queue
        await asyncio.sleep(0)
        for first in (0, 5, 10, 15):  # the queue holds 2 packets: 10 and 15 overflow
            self.fw.client.send_signal(first)
        got = [await pending, await iterator.__anext__()]
        self.fw.client.send_signal(20)
        got.append(await asyncio.wait_for(iterator.__anext__(), 1))
        self.assertEqual([p.first_index for p in got], [0, 5, 20])
        self.assertEqual([p.gap_before for p in got], [False, False, True])  # 10 and 15 were dropped
        self.fw.client.drop_link()
        with self.assertRaises(StopAsyncIteration):
            await iterator.__anext__()


if __name__ == "__main__":
    unittest.main()
