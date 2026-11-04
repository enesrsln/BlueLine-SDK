package com.blueline.sdk

/**
 * One EEG notification: up to 19 consecutive samples of every channel.
 *
 * Sample `i` has index `firstIndex + i` and time `index / signalRateHz` seconds
 * since START_SIGNAL of its [session].
 */
public class BlueLineSignalPacket internal constructor(
    /**
     * Samples before [firstIndex] were lost: on the device (firmware flag), over BLE
     * (the index did not continue), or because the app did not consume packets fast enough.
     * Do not interpolate silently; mark the gap in your analysis.
     */
    public val gapBefore: Boolean,
    public val session: Int,
    /** Sample index of the first sample since START_SIGNAL (unsigned 32-bit). */
    public val firstIndex: Long,
    /** Raw signed 24-bit ADC counts as `[sample][channel]`. */
    public val samples: Array<IntArray>,
    /** Scale of this packet's session; 0 if unknown (packet parsed without a tracker). */
    public val microvoltsPerCount: Double,
) {
    public val sampleCount: Int get() = samples.size
    public val channelCount: Int get() = samples.firstOrNull()?.size ?: 0

    /** Samples in microvolts as `[sample][channel]`. */
    public val microvolts: Array<DoubleArray>
        get() = Array(samples.size) { s -> DoubleArray(samples[s].size) { c -> samples[s][c] * microvoltsPerCount } }

    /** Index of the next sample after this packet (wraps at 2^32). */
    public val nextIndex: Long get() = (firstIndex + samples.size) and U32_MASK

    internal fun with(gapBefore: Boolean, microvoltsPerCount: Double): BlueLineSignalPacket =
        BlueLineSignalPacket(gapBefore, session, firstIndex, samples, microvoltsPerCount)

    override fun toString(): String =
        "BlueLineSignalPacket(session=$session, firstIndex=$firstIndex, samples=${samples.size}, gapBefore=$gapBefore)"

    public companion object {
        /**
         * Decodes the raw notification. Returns null if the length does not match
         * `8 + count * channelCount * 3` exactly.
         */
        @JvmStatic
        public fun parse(data: ByteArray?, channelCount: Int): BlueLineSignalPacket? {
            val header = BlueLineV1.SIGNAL_HEADER_BYTES
            if (data == null || channelCount <= 0 || data.size <= header) return null
            val r = ByteReader(data)
            val count = r.u8(1)
            val stride = channelCount * BlueLineV1.BYTES_PER_CHANNEL_SAMPLE
            if (count <= 0 || data.size != header + count * stride) return null
            val samples = Array(count) { s ->
                IntArray(channelCount) { c -> r.int24BE(header + s * stride + c * BlueLineV1.BYTES_PER_CHANNEL_SAMPLE) }
            }
            return BlueLineSignalPacket(
                gapBefore = r.u8(0) and 0x01 != 0,
                session = r.u16(2),
                firstIndex = r.u32(4),
                samples = samples,
                microvoltsPerCount = 0.0,
            )
        }
    }
}
