package com.blueline.sdk

public enum class BlueLineStatusFlag(public val bit: Int) {
    MEMS_ON(0),
    /** The BLE TX queue was full; signal samples are being dropped. */
    TX_BLOCKED(1),
    ADS_FAULT(2),
    ADXL_FAULT(3);

    public companion object {
        @JvmStatic
        public fun fromBits(bits: Int): Set<BlueLineStatusFlag> =
            entries.filterTo(LinkedHashSet()) { bits and (1 shl it.bit) != 0 }
    }
}

/**
 * Device state and per-session loss counters (20 bytes). State, flag and gain
 * changes notify immediately; counter-only changes at most once per second.
 */
public data class BlueLineStatus(
    val isStreaming: Boolean,
    val flagBits: Int,
    val batteryPercent: Int,
    val gain: Int,
    /** Effective ATT MTU. */
    val mtu: Int,
    val session: Int,
    /** Samples dropped because the BLE queue was full, this session. */
    val signalSamplesDropped: Long,
    /** ADC frames lost before processing, this session. */
    val adcFramesLost: Long,
    val memsSamplesDropped: Long,
) {
    val flags: Set<BlueLineStatusFlag> get() = BlueLineStatusFlag.fromBits(flagBits)

    public fun has(flag: BlueLineStatusFlag): Boolean = flagBits and (1 shl flag.bit) != 0

    public companion object {
        public const val BYTE_COUNT: Int = 20

        @JvmStatic
        public fun parse(data: ByteArray?): BlueLineStatus? {
            if (data == null || data.size < BYTE_COUNT) return null
            val r = ByteReader(data)
            return BlueLineStatus(
                isStreaming = r.u8(0) == 1,
                flagBits = r.u8(1),
                batteryPercent = r.u8(2),
                gain = r.u8(3),
                mtu = r.u16(4),
                session = r.u16(6),
                signalSamplesDropped = r.u32(8),
                adcFramesLost = r.u32(12),
                memsSamplesDropped = r.u32(16),
            )
        }
    }
}
