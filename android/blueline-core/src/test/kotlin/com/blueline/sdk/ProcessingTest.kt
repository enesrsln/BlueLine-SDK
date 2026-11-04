package com.blueline.sdk

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Runs testvectors/blueline_processing_v1.json and checks the processing classes. */
class ProcessingTest {
    private val fs = 250.0

    private val vectors: JSONObject by lazy {
        val path = System.getProperty("blueline.processingvectors")
            ?: error("system property blueline.processingvectors is not set (run through Gradle)")
        JSONObject(File(path).readText())
    }

    private fun JSONArray.doubles(): DoubleArray = DoubleArray(length()) { getDouble(it) }
    private fun JSONObject.values(): DoubleArray = DoubleArray(length()) { getDouble(names().getString(it)) }

    private fun assertClose(expected: DoubleArray, actual: DoubleArray, name: String) {
        assertEquals(expected.size, actual.size, "$name: size")
        val tol = 1e-9 * maxOf(1e-12, expected.maxOf { abs(it) })
        for (i in expected.indices) {
            assertTrue(abs(expected[i] - actual[i]) <= tol, "$name[$i]: expected ${expected[i]}, got ${actual[i]}")
        }
    }

    private fun bands(): Map<String, Band> {
        val o = vectors.getJSONObject("bands")
        val m = LinkedHashMap<String, Band>()
        for (k in o.keys()) o.getJSONArray(k).let { m[k] = Band(it.getDouble(0), it.getDouble(1)) }
        return m
    }

    /** Values of a JSON object in the order of [keys]. */
    private fun JSONObject.ordered(keys: Collection<String>) = keys.map { getDouble(it) }.toDoubleArray()

    @Test
    fun filterVectors() {
        val cases = vectors.getJSONArray("filters")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val name = c.getString("name")
            val sr = c.getDouble("sampleRate")
            val f = when (c.getString("type")) {
                "lowpass" -> BlueLineFilter.lowpass(sr, c.getDouble("frequency"), c.getInt("order"))
                "highpass" -> BlueLineFilter.highpass(sr, c.getDouble("frequency"), c.getInt("order"))
                "notch" -> BlueLineFilter.notch(sr, c.getDouble("frequency"), c.getDouble("quality"))
                else -> error("unknown filter type")
            }
            val sections = c.getJSONArray("sections")
            val expected = (0 until sections.length()).flatMap { sections.getJSONArray(it).doubles().toList() }
            assertClose(expected.toDoubleArray(), f.sections.flatMap { it.coefficients.toList() }.toDoubleArray(), "$name coefficients")
            assertClose(c.getJSONArray("output").doubles(), f.filterArray(c.getJSONArray("input").doubles()), name)
        }
    }

    @Test
    fun defaultSignalFilterVector() {
        val c = vectors.getJSONObject("signalFilterDefault")
        val input = c.getJSONArray("input").doubles()
        val out = SignalFilter(1, c.getDouble("sampleRate")).filterRows(Array(input.size) { doubleArrayOf(input[it]) })
        assertClose(c.getJSONArray("output").doubles(), DoubleArray(out.size) { out[it][0] }, "default chain")
    }

    @Test
    fun spectrumVectors() {
        val bands = bands()
        val cases = vectors.getJSONArray("spectrum")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val name = c.getString("name")
            val s = BlueLineSpectrum.powerSpectrum(
                c.getJSONArray("input").doubles(), c.getDouble("sampleRate"), c.getInt("nfft"), c.getDouble("maxFrequency"),
            )
            assertClose(c.getJSONArray("frequencies").doubles(), s.frequencies, "$name frequencies")
            assertClose(c.getJSONArray("psd").doubles(), s.psd, "$name psd")
            val powers = BlueLineSpectrum.bandPowers(s, bands)
            assertClose(c.getJSONObject("bandPowers").ordered(powers.keys), powers.values.toDoubleArray(), "$name powers")
            if (c.has("relative")) {
                val rel = BlueLineSpectrum.relativePowers(powers, bands)
                assertClose(c.getJSONObject("relative").ordered(rel.keys), rel.values.toDoubleArray(), "$name relative")
                val norm = BlueLineSpectrum.relativePowers(powers, bands, normalizeByBandwidth = true)
                assertClose(
                    c.getJSONObject("relativeNormalizedByBandwidth").ordered(norm.keys), norm.values.toDoubleArray(),
                    "$name relative normalized",
                )
            }
        }
    }

    @Test
    fun responses() {
        val notch = BlueLineFilter.notch(fs, 50.0)
        assertTrue(notch.response(50.0, fs) < 1e-6)
        assertEquals(1.0, notch.response(10.0, fs), 0.01)
        for (order in listOf(2, 4, 6, 8)) {
            assertEquals(sqrt(0.5), BlueLineFilter.lowpass(fs, 40.0, order).response(40.0, fs), 1e-9)
            assertEquals(sqrt(0.5), BlueLineFilter.highpass(fs, 0.5, order).response(0.5, fs), 1e-9)
        }
        assertTrue(BlueLineFilter.highpass(fs, 0.5).filterArray(DoubleArray(500) { 10000.0 }).all { abs(it) < 1e-6 })
    }

    private fun packet(session: Int, first: Long, rows: List<DoubleArray>, gap: Boolean = false) =
        BlueLineSignalPacket(gap, session, first, Array(rows.size) { r -> IntArray(rows[r].size) { rows[r][it].toInt() } }, 1.0)

    @Test
    fun signalFilterResetsOnGapAndSession() {
        val filt = SignalFilter(1, fs)
        filt.process(packet(1, 0, List(5) { doubleArrayOf(0.0) }))
        assertTrue(abs(filt.process(packet(1, 5, listOf(doubleArrayOf(5000.0))))[0][0]) > 1e-3)
        assertEquals(0.0, filt.process(packet(1, 20, listOf(doubleArrayOf(5000.0)), gap = true))[0][0], 1e-6)
        assertEquals(0.0, filt.process(packet(2, 0, listOf(doubleArrayOf(-300.0))))[0][0], 1e-6)
    }

    private fun feed(an: SpectrumAnalyzer, session: Int, first: Long, n: Int, gap: Boolean = false): List<SpectrumFrame> {
        val frames = ArrayList<SpectrumFrame>()
        var i = 0
        while (i < n) {
            val rows = (i until minOf(n, i + 10)).map { k ->
                val v = 3000.0 * sin(2 * PI * 10.0 * (first + k) / fs)
                doubleArrayOf(v, -v)
            }
            frames += an.process(packet(session, first + i, rows, gap && i == 0))
            i += 10
        }
        return frames
    }

    @Test
    fun analyzerFramesAndRestarts() {
        val an = SpectrumAnalyzer(2, fs)
        val frames = feed(an, 1, 0, 1500)
        assertEquals((1000..1500 step 50).map { it.toLong() }, frames.map { it.endIndex })
        val last = frames.last()
        assertEquals(6.0, last.endTime(fs), 1e-12)
        assertTrue(last.channels[0].relative.getValue("alpha") > 0.99)
        assertEquals(3000.0 * 3000.0 / 2, last.channels[0].powers.getValue("alpha"), 3000.0 * 3000.0 / 2 * 0.01)
        assertEquals(1.0, last.channels[1].relative.values.sum(), 1e-12)

        val an2 = SpectrumAnalyzer(2, fs)
        feed(an2, 1, 0, 900)
        assertEquals(0.9, an2.fill, 1e-12)
        assertTrue(feed(an2, 1, 1000, 900, gap = true).isEmpty())
        assertTrue(feed(an2, 2, 0, 990).isEmpty())
        assertEquals(1, feed(an2, 2, 990, 10).size)
    }
}
