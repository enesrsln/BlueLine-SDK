package com.blueline.sdk

/** Capabilities from the Info `features` bitmask. */
public enum class BlueLineFeature(public val bit: Int) {
    SIGNAL(0),
    MEMS(1),
    /** Impedance measurement (reserved; not implemented by firmware 0.3.x). */
    RESIST(2),
    IDENTIFY(3),
    SET_GAIN(4);

    public companion object {
        @JvmStatic
        public fun fromBits(bits: Int): Set<BlueLineFeature> =
            entries.filterTo(LinkedHashSet()) { bits and (1 shl it.bit) != 0 }
    }
}

/** Static device description, read once after connecting (32 bytes). */
public data class BlueLineInfo(
    val protocolVersion: Int,
    val model: Int,
    /** The Device Information serial number is a factory serial (otherwise the chip id). */
    val hasFactorySerial: Boolean,
    val channelCount: Int,
    val firmwareMajor: Int,
    val firmwareMinor: Int,
    val firmwarePatch: Int,
    val adcBits: Int,
    val adcRateHz: Int,
    /** EEG output rate (250 Hz). */
    val signalRateHz: Int,
    /** ADC samples averaged per output sample (4). */
    val decimation: Int,
    /** Current PGA gain; `BlueLineDevice.info` follows `setGain`. */
    val gain: Int,
    val vrefMicrovolts: Long,
    val memsRateHz: Int,
    val maxSamplesPerPacket: Int,
    val signalHeaderBytes: Int,
    val featureBits: Int,
    /** 64-bit chip id (FICR DEVICEID) as a bit pattern; see [chipIdHex]. */
    val chipId: Long,
) {
    val features: Set<BlueLineFeature> get() = BlueLineFeature.fromBits(featureBits)

    public fun supports(feature: BlueLineFeature): Boolean = featureBits and (1 shl feature.bit) != 0

    val firmwareVersion: String get() = "$firmwareMajor.$firmwareMinor.$firmwarePatch"

    /** 16 uppercase hex characters, as reported by the Device Information serial without a factory serial. */
    val chipIdHex: String get() = String.format("%016X", chipId)

    /** uV = code * vref_uV / (gain * 2^23) */
    val microvoltsPerCount: Double get() = vrefMicrovolts.toDouble() / (gain.toDouble() * 8_388_608.0)

    /** Fields the decoder relies on match this SDK. */
    val isSupported: Boolean
        get() = protocolVersion == BlueLineV1.PROTOCOL_VERSION &&
            signalHeaderBytes == BlueLineV1.SIGNAL_HEADER_BYTES &&
            supports(BlueLineFeature.SIGNAL)

    public companion object {
        public const val BYTE_COUNT: Int = 32

        /** Returns null for short or malformed data (zero channels, rate, gain or reference). */
        @JvmStatic
        public fun parse(data: ByteArray?): BlueLineInfo? {
            if (data == null || data.size < BYTE_COUNT) return null
            val r = ByteReader(data)
            val info = BlueLineInfo(
                protocolVersion = r.u8(0),
                model = r.u8(1),
                hasFactorySerial = r.u8(2) and 0x01 != 0,
                channelCount = r.u8(3),
                firmwareMajor = r.u8(4),
                firmwareMinor = r.u8(5),
                firmwarePatch = r.u8(6),
                adcBits = r.u8(7),
                adcRateHz = r.u16(8),
                signalRateHz = r.u16(10),
                decimation = r.u8(12),
                gain = r.u8(13),
                vrefMicrovolts = r.u32(14),
                memsRateHz = r.u16(18),
                maxSamplesPerPacket = r.u8(20),
                signalHeaderBytes = r.u8(21),
                featureBits = r.u16(22),
                chipId = r.u64(24),
            )
            if (info.channelCount <= 0 || info.signalRateHz <= 0 || info.gain <= 0 || info.vrefMicrovolts <= 0) {
                return null
            }
            return info
        }
    }
}
