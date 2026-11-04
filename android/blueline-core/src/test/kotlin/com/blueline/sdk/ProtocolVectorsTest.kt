package com.blueline.sdk

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/** Runs the shared test vectors (mobile/testvectors/blueline_protocol_v1.json). */
class ProtocolVectorsTest {
    private val vectors: JSONObject by lazy {
        val path = System.getProperty("blueline.testvectors")
            ?: error("system property blueline.testvectors is not set (run through Gradle)")
        JSONObject(File(path).readText())
    }

    private fun cases(name: String): List<JSONObject> {
        val array = vectors.getJSONArray(name)
        return (0 until array.length()).map { array.getJSONObject(it) }
    }

    private fun hex(s: String): ByteArray = ByteArray(s.length / 2) { s.substring(2 * it, 2 * it + 2).toInt(16).toByte() }

    private fun JSONObject.expect(): JSONObject? = if (isNull("expect")) null else getJSONObject("expect")

    private fun names(array: JSONArray): Set<String> = (0 until array.length()).map { array.getString(it) }.toSet()

    @Test
    fun info() {
        for (case in cases("info")) {
            val name = case.getString("name")
            val info = BlueLineInfo.parse(hex(case.getString("hex")))
            val expect = case.expect()
            if (expect == null) {
                assertNull(info, name); continue
            }
            assertNotNull(info, name)
            for (key in expect.keys()) {
                when (key) {
                    "protocolVersion" -> assertEquals(expect.getInt(key), info.protocolVersion, name)
                    "model" -> assertEquals(expect.getInt(key), info.model, name)
                    "hasFactorySerial" -> assertEquals(expect.getBoolean(key), info.hasFactorySerial, name)
                    "channelCount" -> assertEquals(expect.getInt(key), info.channelCount, name)
                    "firmwareVersion" -> assertEquals(expect.getString(key), info.firmwareVersion, name)
                    "adcBits" -> assertEquals(expect.getInt(key), info.adcBits, name)
                    "adcRateHz" -> assertEquals(expect.getInt(key), info.adcRateHz, name)
                    "signalRateHz" -> assertEquals(expect.getInt(key), info.signalRateHz, name)
                    "decimation" -> assertEquals(expect.getInt(key), info.decimation, name)
                    "gain" -> assertEquals(expect.getInt(key), info.gain, name)
                    "vrefMicrovolts" -> assertEquals(expect.getLong(key), info.vrefMicrovolts, name)
                    "memsRateHz" -> assertEquals(expect.getInt(key), info.memsRateHz, name)
                    "maxSamplesPerPacket" -> assertEquals(expect.getInt(key), info.maxSamplesPerPacket, name)
                    "signalHeaderBytes" -> assertEquals(expect.getInt(key), info.signalHeaderBytes, name)
                    "featureBits" -> assertEquals(expect.getInt(key), info.featureBits, name)
                    "features" -> assertEquals(
                        names(expect.getJSONArray(key)),
                        info.features.map { featureName(it) }.toSet(), name,
                    )
                    "chipIdHex" -> assertEquals(expect.getString(key), info.chipIdHex, name)
                    "microvoltsPerCount" -> assertEquals(expect.getDouble(key), info.microvoltsPerCount, 1e-12, name)
                    "isSupported" -> assertEquals(expect.getBoolean(key), info.isSupported, name)
                    else -> error("unknown info key $key")
                }
            }
        }
    }

    private fun featureName(f: BlueLineFeature) = when (f) {
        BlueLineFeature.SIGNAL -> "signal"
        BlueLineFeature.MEMS -> "mems"
        BlueLineFeature.RESIST -> "resist"
        BlueLineFeature.IDENTIFY -> "identify"
        BlueLineFeature.SET_GAIN -> "setGain"
    }

    @Test
    fun signal() {
        for (case in cases("signal")) {
            val name = case.getString("name")
            val packet = BlueLineSignalPacket.parse(hex(case.getString("hex")), case.getInt("channelCount"))
            val expect = case.expect()
            if (expect == null) {
                assertNull(packet, name); continue
            }
            assertNotNull(packet, name)
            assertEquals(expect.getBoolean("gapBefore"), packet.gapBefore, name)
            assertEquals(expect.getInt("session"), packet.session, name)
            assertEquals(expect.getLong("firstIndex"), packet.firstIndex, name)
            if (expect.has("sampleCount")) assertEquals(expect.getInt("sampleCount"), packet.sampleCount, name)
            if (expect.has("samples")) {
                val rows = expect.getJSONArray("samples")
                assertEquals(rows.length(), packet.sampleCount, name)
                for (s in 0 until rows.length()) {
                    val row = rows.getJSONArray(s)
                    assertContentEquals(IntArray(row.length()) { row.getInt(it) }, packet.samples[s], "$name sample $s")
                }
            }
        }
    }

    @Test
    fun mems() {
        for (case in cases("mems")) {
            val name = case.getString("name")
            val sample = BlueLineMemsSample.parse(hex(case.getString("hex")))
            val expect = case.expect()
            if (expect == null) {
                assertNull(sample, name); continue
            }
            assertNotNull(sample, name)
            assertEquals(expect.getInt("session"), sample.session, name)
            assertEquals(expect.getLong("memsIndex"), sample.memsIndex, name)
            assertEquals(if (expect.isNull("signalIndex")) null else expect.getLong("signalIndex"), sample.signalIndex, name)
            assertEquals(listOf(expect.getInt("x"), expect.getInt("y"), expect.getInt("z")), listOf(sample.x, sample.y, sample.z), name)
            if (expect.has("zG")) assertEquals(expect.getDouble("zG"), sample.zG, 1e-9, name)
        }
    }

    @Test
    fun status() {
        for (case in cases("status")) {
            val name = case.getString("name")
            val status = BlueLineStatus.parse(hex(case.getString("hex")))
            val expect = case.expect()
            if (expect == null) {
                assertNull(status, name); continue
            }
            assertNotNull(status, name)
            assertEquals(expect.getBoolean("isStreaming"), status.isStreaming, name)
            val flagNames = mapOf(
                BlueLineStatusFlag.MEMS_ON to "memsOn", BlueLineStatusFlag.TX_BLOCKED to "txBlocked",
                BlueLineStatusFlag.ADS_FAULT to "adsFault", BlueLineStatusFlag.ADXL_FAULT to "adxlFault",
            )
            assertEquals(names(expect.getJSONArray("flags")), status.flags.map { flagNames.getValue(it) }.toSet(), name)
            assertEquals(expect.getInt("batteryPercent"), status.batteryPercent, name)
            assertEquals(expect.getInt("gain"), status.gain, name)
            assertEquals(expect.getInt("mtu"), status.mtu, name)
            assertEquals(expect.getInt("session"), status.session, name)
            assertEquals(expect.getLong("signalSamplesDropped"), status.signalSamplesDropped, name)
            assertEquals(expect.getLong("adcFramesLost"), status.adcFramesLost, name)
            assertEquals(expect.getLong("memsSamplesDropped"), status.memsSamplesDropped, name)
        }
    }

    @Test
    fun controlRequests() {
        val commands = mapOf("startSignal" to BlueLineCommand.START_SIGNAL, "setGain" to BlueLineCommand.SET_GAIN)
        for (case in cases("controlRequest")) {
            val params = case.getJSONArray("params").let { a -> IntArray(a.length()) { a.getInt(it) } }
            val bytes = commands.getValue(case.getString("command")).request(*params)
            assertContentEquals(hex(case.getString("hex")), bytes, case.getString("command"))
        }
    }

    @Test
    fun controlResponses() {
        val results = mapOf(
            "ok" to BlueLineResult.OK, "notSupported" to BlueLineResult.NOT_SUPPORTED,
            "invalidParam" to BlueLineResult.INVALID_PARAM, "invalidState" to BlueLineResult.INVALID_STATE,
            "busy" to BlueLineResult.BUSY, "hardwareFault" to BlueLineResult.HARDWARE_FAULT,
        )
        for (case in cases("controlResponse")) {
            val name = case.getString("name")
            val response = BlueLineControlResponse.parse(hex(case.getString("hex")))
            val expect = case.expect()
            if (expect == null) {
                assertNull(response, name); continue
            }
            assertNotNull(response, name)
            assertEquals(expect.getInt("opcode"), response.opcode, name)
            assertEquals(results.getValue(expect.getString("result")), response.result, name)
            assertEquals(if (expect.isNull("session")) null else expect.getInt("session"), response.session, name)
        }
    }

    @Test
    fun advertisement() {
        for (case in cases("advertisement")) {
            val name = case.getString("name")
            val full = hex(case.getString("manufacturerDataHex"))
            val fromFull = BlueLineAdvertisement.fromManufacturerData(full)
            // Android hands over the payload after the 2-byte company id.
            val fromPayload = if (full.size >= 2 && (full[0].toInt() and 0xFF) == 0xFF && (full[1].toInt() and 0xFF) == 0xFF) {
                BlueLineAdvertisement.fromCompanyPayload(full.copyOfRange(2, full.size))
            } else null
            val expect = case.expect()
            if (expect == null) {
                assertNull(fromFull, name); assertNull(fromPayload, name); continue
            }
            val expected = BlueLineAdvertisement(expect.getInt("model"), expect.getLong("chipIdLow"))
            assertEquals(expected, fromFull, name)
            assertEquals(expected, fromPayload, name)
        }
    }
}
