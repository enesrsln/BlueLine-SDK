"""Runs the shared test vectors (../testvectors/blueline_protocol_v1.json)."""

import json
import pathlib
import unittest

from blueline.protocol import (
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

VECTORS = json.loads(
    (pathlib.Path(__file__).resolve().parents[2] / "testvectors" / "blueline_protocol_v1.json").read_text("utf-8")
)

FEATURES = {"signal": Feature.SIGNAL, "mems": Feature.MEMS, "resist": Feature.RESIST,
            "identify": Feature.IDENTIFY, "setGain": Feature.SET_GAIN}
FLAGS = {"memsOn": StatusFlag.MEMS_ON, "txBlocked": StatusFlag.TX_BLOCKED,
         "adsFault": StatusFlag.ADS_FAULT, "adxlFault": StatusFlag.ADXL_FAULT}
RESULTS = {"ok": Result.OK, "notSupported": Result.NOT_SUPPORTED, "invalidParam": Result.INVALID_PARAM,
           "invalidState": Result.INVALID_STATE, "busy": Result.BUSY, "hardwareFault": Result.HARDWARE_FAULT}
COMMANDS = {"startSignal": Command.START_SIGNAL, "setGain": Command.SET_GAIN}

# JSON key -> (attribute, converter)
INFO_KEYS = {
    "protocolVersion": "protocol_version", "model": "model", "hasFactorySerial": "has_factory_serial",
    "channelCount": "channel_count", "firmwareVersion": "firmware_version", "adcBits": "adc_bits",
    "adcRateHz": "adc_rate_hz", "signalRateHz": "signal_rate_hz", "decimation": "decimation", "gain": "gain",
    "vrefMicrovolts": "vref_microvolts", "memsRateHz": "mems_rate_hz",
    "maxSamplesPerPacket": "max_samples_per_packet", "signalHeaderBytes": "signal_header_bytes",
    "featureBits": "feature_bits", "chipIdHex": "chip_id_hex", "isSupported": "is_supported",
}


def cases(name):
    return VECTORS[name]


class VectorTests(unittest.TestCase):
    def test_info(self):
        for case in cases("info"):
            with self.subTest(case["name"]):
                info = Info.parse(bytes.fromhex(case["hex"]))
                expect = case["expect"]
                if expect is None:
                    self.assertIsNone(info)
                    continue
                self.assertIsNotNone(info)
                for key, value in expect.items():
                    if key == "features":
                        wanted = Feature(0)
                        for n in value:
                            wanted |= FEATURES[n]
                        self.assertEqual(info.features, wanted)
                    elif key == "microvoltsPerCount":
                        self.assertAlmostEqual(info.microvolts_per_count, value, places=12)
                    else:
                        self.assertEqual(getattr(info, INFO_KEYS[key]), value, key)

    def test_signal(self):
        for case in cases("signal"):
            with self.subTest(case["name"]):
                packet = SignalPacket.parse(bytes.fromhex(case["hex"]), case["channelCount"])
                expect = case["expect"]
                if expect is None:
                    self.assertIsNone(packet)
                    continue
                self.assertEqual(packet.gap_before, expect["gapBefore"])
                self.assertEqual(packet.session, expect["session"])
                self.assertEqual(packet.first_index, expect["firstIndex"])
                if "sampleCount" in expect:
                    self.assertEqual(packet.sample_count, expect["sampleCount"])
                if "samples" in expect:
                    self.assertEqual([list(r) for r in packet.samples], expect["samples"])

    def test_mems(self):
        for case in cases("mems"):
            with self.subTest(case["name"]):
                sample = MemsSample.parse(bytes.fromhex(case["hex"]))
                expect = case["expect"]
                if expect is None:
                    self.assertIsNone(sample)
                    continue
                self.assertEqual(sample.session, expect["session"])
                self.assertEqual(sample.mems_index, expect["memsIndex"])
                self.assertEqual(sample.signal_index, expect["signalIndex"])
                self.assertEqual((sample.x, sample.y, sample.z), (expect["x"], expect["y"], expect["z"]))
                if "zG" in expect:
                    self.assertAlmostEqual(sample.z_g, expect["zG"], places=9)

    def test_status(self):
        for case in cases("status"):
            with self.subTest(case["name"]):
                status = Status.parse(bytes.fromhex(case["hex"]))
                expect = case["expect"]
                if expect is None:
                    self.assertIsNone(status)
                    continue
                wanted = StatusFlag(0)
                for n in expect["flags"]:
                    wanted |= FLAGS[n]
                self.assertEqual(status.flags, wanted)
                self.assertEqual(status.is_streaming, expect["isStreaming"])
                self.assertEqual(status.battery_percent, expect["batteryPercent"])
                self.assertEqual(status.gain, expect["gain"])
                self.assertEqual(status.mtu, expect["mtu"])
                self.assertEqual(status.session, expect["session"])
                self.assertEqual(status.signal_samples_dropped, expect["signalSamplesDropped"])
                self.assertEqual(status.adc_frames_lost, expect["adcFramesLost"])
                self.assertEqual(status.mems_samples_dropped, expect["memsSamplesDropped"])

    def test_control_requests(self):
        for case in cases("controlRequest"):
            with self.subTest(case["command"]):
                self.assertEqual(COMMANDS[case["command"]].request(*case["params"]), bytes.fromhex(case["hex"]))

    def test_control_responses(self):
        for case in cases("controlResponse"):
            with self.subTest(case["name"]):
                response = ControlResponse.parse(bytes.fromhex(case["hex"]))
                expect = case["expect"]
                if expect is None:
                    self.assertIsNone(response)
                    continue
                self.assertEqual(response.opcode, expect["opcode"])
                self.assertEqual(response.result, RESULTS[expect["result"]])
                self.assertEqual(response.session, expect["session"])

    def test_advertisement(self):
        for case in cases("advertisement"):
            with self.subTest(case["name"]):
                full = bytes.fromhex(case["manufacturerDataHex"])
                from_full = Advertisement.from_manufacturer_data(full)
                # bleak hands over the payload after the company id.
                from_payload = Advertisement.from_company_payload(full[2:]) if full[:2] == b"\xff\xff" else None
                expect = case["expect"]
                if expect is None:
                    self.assertIsNone(from_full)
                    self.assertIsNone(from_payload)
                    continue
                wanted = Advertisement(expect["model"], expect["chipIdLow"])
                self.assertEqual(from_full, wanted)
                self.assertEqual(from_payload, wanted)


if __name__ == "__main__":
    unittest.main()
