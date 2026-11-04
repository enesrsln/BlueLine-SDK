package com.blueline.sdk

/** One accelerometer sample (ADXL345, 100 Hz, raw counts, gravity included). 16 bytes. */
public data class BlueLineMemsSample(
    val session: Int,
    val memsIndex: Long,
    /**
     * EEG sample index when this sample was read; null while the signal is stopped.
     * Approximate alignment, not a hardware-synchronized timestamp.
     */
    val signalIndex: Long?,
    val x: Int,
    val y: Int,
    val z: Int,
) {
    /** Acceleration in g (about 1 g in total at rest). */
    val xG: Double get() = x * G_PER_COUNT
    val yG: Double get() = y * G_PER_COUNT
    val zG: Double get() = z * G_PER_COUNT

    public companion object {
        public const val BYTE_COUNT: Int = 16

        /** ADXL345 full resolution: 3.9 mg per count. */
        public const val G_PER_COUNT: Double = 0.0039

        @JvmStatic
        public fun parse(data: ByteArray?): BlueLineMemsSample? {
            if (data == null || data.size < BYTE_COUNT) return null
            val r = ByteReader(data)
            val index = r.u32(6)
            return BlueLineMemsSample(
                session = r.u16(0),
                memsIndex = r.u32(2),
                signalIndex = if (index == U32_MASK) null else index,
                x = r.i16(10),
                y = r.i16(12),
                z = r.i16(14),
            )
        }
    }
}
