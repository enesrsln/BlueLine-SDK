package com.blueline.sdk

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.tan

/*
 * EEG signal processing: filters, spectrum and band powers.
 *
 * The same algorithms as the other BlueLine SDKs, checked by
 * testvectors/blueline_processing_v1.json. Pure Kotlin, no Android dependency.
 * The classes keep state and are not thread-safe: use each from one thread
 * (for example the collector of BlueLineDevice.signal).
 */

/** An EEG frequency band in Hz, `low <= f < high`. */
public data class Band(val low: Double, val high: Double) {
    init {
        require(low < high) { "low must be below high" }
    }

    val width: Double get() = high - low
}

/** Default EEG bands. */
public val EEG_BANDS: Map<String, Band> = linkedMapOf(
    "delta" to Band(1.0, 4.0),
    "theta" to Band(4.0, 8.0),
    "alpha" to Band(8.0, 13.0),
    "beta" to Band(13.0, 30.0),
    "gamma" to Band(30.0, 45.0),
)

// ------------------------------------------------------------------- filters

/**
 * One second-order IIR section (direct form II transposed), `a0 == 1`.
 * Starts in the steady state of its first input sample, so a large electrode
 * offset does not ring through a high-pass filter.
 */
public class Biquad(
    public val b0: Double,
    public val b1: Double,
    public val b2: Double,
    public val a1: Double,
    public val a2: Double,
) {
    private var s1 = 0.0
    private var s2 = 0.0
    private var started = false

    public val dcGain: Double get() = (b0 + b1 + b2) / (1.0 + a1 + a2)

    /** `(b0, b1, b2, a1, a2)`. */
    public val coefficients: DoubleArray get() = doubleArrayOf(b0, b1, b2, a1, a2)

    /** Forgets the past; the next sample sets the starting state again. */
    public fun reset() {
        s1 = 0.0; s2 = 0.0; started = false
    }

    public fun filter(x: Double): Double {
        if (!started) {
            val g = dcGain
            s2 = (b2 - a2 * g) * x
            s1 = (b1 - a1 * g) * x + s2
            started = true
        }
        val y = b0 * x + s1
        s1 = b1 * x - a1 * y + s2
        s2 = b2 * x - a2 * y
        return y
    }

    /** Magnitude response at [frequency]. */
    internal fun response(frequency: Double, sampleRate: Double): Double {
        val w = 2.0 * PI * frequency / sampleRate
        // H(e^jw) with z^-1 = e^-jw
        val c1 = cos(w); val n1 = -sin(w); val c2 = cos(2 * w); val n2 = -sin(2 * w)
        val nr = b0 + b1 * c1 + b2 * c2; val ni = b1 * n1 + b2 * n2
        val dr = 1.0 + a1 * c1 + a2 * c2; val di = a1 * n1 + a2 * n2
        return hypot(nr, ni) / hypot(dr, di)
    }

    internal fun copy(): Biquad = Biquad(b0, b1, b2, a1, a2)
}

/** A cascade of biquads for one channel. Build one with the companion functions. */
public class BlueLineFilter(sections: List<Biquad>, public val description: String = "custom") {
    public val sections: List<Biquad> = sections.toList()

    public fun reset(): Unit = sections.forEach { it.reset() }

    public fun filter(x: Double): Double {
        var v = x
        for (s in sections) v = s.filter(v)
        return v
    }

    public fun filterArray(values: DoubleArray): DoubleArray = DoubleArray(values.size) { filter(values[it]) }

    /** Magnitude response (1.0 = passes unchanged) at [frequency]. */
    public fun response(frequency: Double, sampleRate: Double): Double =
        sections.fold(1.0) { acc, s -> acc * s.response(frequency, sampleRate) }

    /** Same coefficients, fresh state (for another channel). */
    public fun copy(): BlueLineFilter = BlueLineFilter(sections.map { it.copy() }, description)

    override fun toString(): String = "BlueLineFilter($description, ${sections.size} sections)"

    public companion object {
        /** Butterworth low-pass; [order] 2, 4, 6 or 8 (-3 dB at [cutoff]). */
        public fun lowpass(sampleRate: Double, cutoff: Double, order: Int = 4): BlueLineFilter {
            val w0 = omega(sampleRate, cutoff)
            return BlueLineFilter(butterworthQs(order).map { q -> section(w0, q, low = true) }, "lowpass ${fmt(cutoff)} Hz")
        }

        /** Butterworth high-pass; removes the electrode offset and slow drift. */
        public fun highpass(sampleRate: Double, cutoff: Double, order: Int = 4): BlueLineFilter {
            val w0 = omega(sampleRate, cutoff)
            return BlueLineFilter(butterworthQs(order).map { q -> section(w0, q, low = false) }, "highpass ${fmt(cutoff)} Hz")
        }

        /** Narrow band-stop for mains: 50 Hz (Europe, Turkey) or 60 Hz. -3 dB width = frequency / quality. */
        public fun notch(sampleRate: Double, frequency: Double = 50.0, quality: Double = 30.0): BlueLineFilter {
            val w0 = omega(sampleRate, frequency)
            require(quality > 0) { "quality must be positive" }
            val g = 1.0 / (1.0 + tan(w0 / quality / 2.0))
            val c = cos(w0)
            return BlueLineFilter(listOf(Biquad(g, -2.0 * g * c, g, -2.0 * g * c, 2.0 * g - 1.0)), "notch ${fmt(frequency)} Hz")
        }

        /** High-pass at [low] followed by low-pass at [high]. */
        public fun bandpass(sampleRate: Double, low: Double, high: Double, order: Int = 4): BlueLineFilter {
            require(low < high) { "low must be below high" }
            return BlueLineFilter(
                highpass(sampleRate, low, order).sections + lowpass(sampleRate, high, order).sections,
                "bandpass ${fmt(low)}-${fmt(high)} Hz",
            )
        }

        private fun fmt(v: Double): String = if (v == v.toLong().toDouble()) v.toLong().toString() else v.toString()

        private fun omega(sampleRate: Double, frequency: Double): Double {
            require(frequency > 0 && frequency < sampleRate / 2) {
                "frequency must be between 0 and ${sampleRate / 2} Hz (Nyquist), got $frequency"
            }
            return 2.0 * PI * frequency / sampleRate
        }

        private fun butterworthQs(order: Int): List<Double> {
            require(order >= 2 && order % 2 == 0) { "order must be an even number >= 2" }
            return (0 until order / 2).map { k -> 1.0 / (2.0 * cos(PI * (2 * k + 1) / (2 * order))) }
        }

        private fun section(w0: Double, q: Double, low: Boolean): Biquad {
            val c = cos(w0)
            val alpha = sin(w0) / (2.0 * q)
            val a0 = 1.0 + alpha
            val b = (if (low) 1.0 - c else 1.0 + c) / 2.0 / a0
            return Biquad(b, if (low) 2.0 * b else -2.0 * b, b, -2.0 * c / a0, (1.0 - alpha) / a0)
        }
    }
}

/** Filters applied one after another to a single channel. */
public class BlueLineFilterList(filters: List<BlueLineFilter> = emptyList()) {
    public val filters: MutableList<BlueLineFilter> = filters.toMutableList()

    public fun add(filter: BlueLineFilter) {
        filters += filter
    }

    public fun reset(): Unit = filters.forEach { it.reset() }

    public fun filter(x: Double): Double {
        var v = x
        for (f in filters) v = f.filter(v)
        return v
    }

    public fun filterArray(values: DoubleArray): DoubleArray = DoubleArray(values.size) { filter(values[it]) }

    public fun response(frequency: Double, sampleRate: Double): Double =
        filters.fold(1.0) { acc, f -> acc * f.response(frequency, sampleRate) }

    public fun copy(): BlueLineFilterList = BlueLineFilterList(filters.map { it.copy() })
}

/** Detects a new session or lost samples between packets. */
private class Continuity {
    private var session: Int? = null

    fun broken(packet: BlueLineSignalPacket): Boolean {
        val broken = packet.gapBefore || packet.session != session
        session = packet.session
        return broken
    }
}

/**
 * The same filter chain on every channel of a stream.
 *
 * Default: 0.5-40 Hz band-pass (4th-order Butterworth) and a 50 Hz notch. Pass
 * `notch = 60.0` in the Americas, `null` to leave a stage out, or your own
 * [filters] to replace the defaults.
 */
public class SignalFilter(
    channelCount: Int,
    public val sampleRate: Double = 250.0,
    highpass: Double? = 0.5,
    lowpass: Double? = 40.0,
    notch: Double? = 50.0,
    order: Int = 4,
    filters: List<BlueLineFilter>? = null,
) {
    public val channels: List<BlueLineFilterList>
    private val continuity = Continuity()

    init {
        val chain = filters?.map { it.copy() } ?: buildList {
            highpass?.let { add(BlueLineFilter.highpass(sampleRate, it, order)) }
            lowpass?.let { add(BlueLineFilter.lowpass(sampleRate, it, order)) }
            notch?.let { add(BlueLineFilter.notch(sampleRate, it)) }
        }
        val template = BlueLineFilterList(chain)
        channels = List(channelCount) { template.copy() }
    }

    public fun reset(): Unit = channels.forEach { it.reset() }

    /** Filters `[sample][channel]` values that continue the previous call. */
    public fun filterRows(rows: Array<DoubleArray>): Array<DoubleArray> =
        Array(rows.size) { s -> DoubleArray(rows[s].size) { c -> channels[c].filter(rows[s][c]) } }

    /**
     * Filtered microvolts of [packet] as `[sample][channel]`. Resets first when the
     * packet starts a new session or follows lost samples; allow 1-2 s to settle.
     */
    public fun process(packet: BlueLineSignalPacket): Array<DoubleArray> {
        if (continuity.broken(packet)) reset()
        return filterRows(packet.microvolts)
    }
}

// ------------------------------------------------------------------ spectrum

/** One-sided power spectral density: [psd] in µV²/Hz at [frequencies] (Hz). */
public class PowerSpectrum(public val frequencies: DoubleArray, public val psd: DoubleArray)

public object BlueLineSpectrum {
    /** Periodic Hann window. */
    public fun hannWindow(n: Int): DoubleArray = DoubleArray(n) { 0.5 - 0.5 * cos(2.0 * PI * it / n) }

    /**
     * PSD of one channel: mean removed, Hann window, zero-padded to [nfft]
     * (default: next power of two), up to [maxFrequency] if given.
     * Matches `scipy.signal.periodogram(x, fs, window="hann", nfft=nfft)`.
     */
    public fun powerSpectrum(
        values: DoubleArray,
        sampleRate: Double,
        nfft: Int? = null,
        maxFrequency: Double? = null,
    ): PowerSpectrum {
        val n = values.size
        require(n >= 2) { "need at least 2 samples" }
        val size = nfft ?: Integer.highestOneBit(max(1, 2 * n - 1))
        require(size >= n && size and (size - 1) == 0) { "nfft must be a power of two and at least values.size" }
        val mean = values.average()
        val window = hannWindow(n)
        val scale = 1.0 / (sampleRate * window.sumOf { it * it })
        val re = DoubleArray(size)
        val im = DoubleArray(size)
        for (i in 0 until n) re[i] = (values[i] - mean) * window[i]
        fft(re, im)
        val df = sampleRate / size
        var bins = size / 2 + 1
        if (maxFrequency != null) bins = (0 until bins).count { it * df <= maxFrequency }
        val psd = DoubleArray(bins) { k ->
            (re[k] * re[k] + im[k] * im[k]) * scale * (if (k == 0 || k == size / 2) 1.0 else 2.0)
        }
        return PowerSpectrum(DoubleArray(bins) { it * df }, psd)
    }

    /** Power in each band (µV² for a µV spectrum): PSD summed over `low <= f < high` times the bin width. */
    public fun bandPowers(spectrum: PowerSpectrum, bands: Map<String, Band> = EEG_BANDS): Map<String, Double> {
        val f = spectrum.frequencies
        require(f.size >= 2) { "need at least 2 frequency bins" }
        val df = f[1] - f[0]
        return bands.mapValues { (_, band) ->
            var sum = 0.0
            for (k in f.indices) if (f[k] >= band.low && f[k] < band.high) sum += spectrum.psd[k]
            sum * df
        }
    }

    /**
     * Each band's share of the total, summing to 1. With [normalizeByBandwidth]
     * each band is first divided by its width, so wide bands do not dominate.
     */
    public fun relativePowers(
        powers: Map<String, Double>,
        bands: Map<String, Band> = EEG_BANDS,
        normalizeByBandwidth: Boolean = false,
    ): Map<String, Double> {
        val p = if (normalizeByBandwidth) powers.mapValues { (k, v) -> v / bands.getValue(k).width } else powers
        val total = p.values.sum()
        return p.mapValues { (_, v) -> if (total > 0) v / total else 0.0 }
    }

    /** In-place radix-2 FFT. */
    private fun fft(re: DoubleArray, im: DoubleArray) {
        val n = re.size
        var j = 0
        for (i in 1 until n) {
            var bit = n shr 1
            while (j and bit != 0) {
                j = j xor bit; bit = bit shr 1
            }
            j = j or bit
            if (i < j) {
                var t = re[i]; re[i] = re[j]; re[j] = t
                t = im[i]; im[i] = im[j]; im[j] = t
            }
        }
        var size = 2
        while (size <= n) {
            val half = size / 2
            val step = -2.0 * PI / size
            for (k in 0 until half) {
                val wr = cos(step * k)
                val wi = sin(step * k)
                var start = k
                while (start < n) {
                    val a = start + half
                    val tr = wr * re[a] - wi * im[a]
                    val ti = wr * im[a] + wi * re[a]
                    re[a] = re[start] - tr; im[a] = im[start] - ti
                    re[start] += tr; im[start] += ti
                    start += size
                }
            }
            size *= 2
        }
    }
}

public class ChannelSpectrum(
    /** PSD in µV²/Hz at [SpectrumFrame.frequencies]. */
    public val psd: DoubleArray,
    /** Absolute band power in µV². */
    public val powers: Map<String, Double>,
    /** Share of each band in the total of all bands (sums to 1). */
    public val relative: Map<String, Double>,
)

/** Spectrum of the last window of every channel. */
public class SpectrumFrame(
    public val session: Int,
    /** Index of the sample after the window. */
    public val endIndex: Long,
    public val frequencies: DoubleArray,
    public val channels: List<ChannelSpectrum>,
) {
    /** Seconds since the session started at the end of the window. */
    public fun endTime(sampleRate: Double): Double = endIndex / sampleRate
}

/**
 * Sliding-window spectrum and band powers of every channel.
 *
 * Keeps the last [window] seconds (default 4 s = 1000 samples at 250 Hz) and
 * computes a [SpectrumFrame] [updateRate] times per second once the window is
 * full. After a new session or lost samples the window fills again, so a frame
 * never spans a gap. Feed it raw microvolts; the mean of each window is removed.
 */
public class SpectrumAnalyzer(
    public val channelCount: Int,
    public val sampleRate: Double = 250.0,
    window: Double = 4.0,
    updateRate: Double = 5.0,
    public val maxFrequency: Double = 50.0,
    public val bands: Map<String, Band> = EEG_BANDS,
    public val normalizeByBandwidth: Boolean = false,
) {
    public val windowSamples: Int = (window * sampleRate).roundToInt()
    public val stepSamples: Int = max(1, (sampleRate / updateRate).roundToInt())
    private val ring = Array(channelCount) { DoubleArray(windowSamples) }
    private var count = 0
    private var head = 0
    private var untilNext = windowSamples
    private var nextIndex = 0L
    private val continuity = Continuity()

    init {
        require(windowSamples >= 16) { "window too short" }
    }

    /** How full the window is, 0.0-1.0. */
    public val fill: Double get() = count.toDouble() / windowSamples

    public fun reset() {
        count = 0; head = 0; untilNext = windowSamples; nextIndex = 0L
    }

    /** Adds a packet; returns the frames it completed (often none, sometimes one). */
    public fun process(packet: BlueLineSignalPacket): List<SpectrumFrame> {
        if (continuity.broken(packet)) reset()
        return addRows(packet.microvolts, packet.session, packet.firstIndex)
    }

    /** Adds `[sample][channel]` values that continue the previous call. */
    public fun addRows(rows: Array<DoubleArray>, session: Int = 0, firstIndex: Long? = null): List<SpectrumFrame> {
        var index = firstIndex ?: nextIndex
        val frames = ArrayList<SpectrumFrame>(1)
        for (row in rows) {
            for (c in 0 until channelCount) ring[c][head] = row[c]
            head = (head + 1) % windowSamples
            if (count < windowSamples) count++
            index++
            if (--untilNext <= 0) {
                untilNext = stepSamples
                frames += compute(session, index and U32_MASK)
            }
        }
        nextIndex = index
        return frames
    }

    private fun compute(session: Int, endIndex: Long): SpectrumFrame {
        var frequencies = DoubleArray(0)
        val channels = ring.map { buf ->
            // oldest sample first
            val ordered = DoubleArray(windowSamples) { buf[(head + it) % windowSamples] }
            val spectrum = BlueLineSpectrum.powerSpectrum(ordered, sampleRate, maxFrequency = maxFrequency)
            frequencies = spectrum.frequencies
            val powers = BlueLineSpectrum.bandPowers(spectrum, bands)
            ChannelSpectrum(spectrum.psd, powers, BlueLineSpectrum.relativePowers(powers, bands, normalizeByBandwidth))
        }
        return SpectrumFrame(session, endIndex, frequencies, channels)
    }
}
