package com.blueline.sdk

/** Control opcodes. */
public enum class BlueLineCommand(public val opcode: Int) {
    START_SIGNAL(0x01),
    STOP_SIGNAL(0x02),
    START_MEMS(0x03),
    STOP_MEMS(0x04),
    START_RESIST(0x05),
    STOP_RESIST(0x06),
    SET_GAIN(0x10),
    IDENTIFY(0x20);

    /** Request bytes: `[opcode] [params...]`. */
    public fun request(vararg params: Int): ByteArray =
        ByteArray(1 + params.size).also { bytes ->
            bytes[0] = opcode.toByte()
            params.forEachIndexed { i, p -> bytes[i + 1] = p.toByte() }
        }

    public companion object {
        /** Answer to a request written while the previous one was still running. */
        public const val BUSY_OPCODE: Int = 0xFF

        /** Gains accepted by SET_GAIN. The device boots with 6. */
        @JvmField
        public val SUPPORTED_GAINS: List<Int> = listOf(1, 2, 4, 6, 8, 12, 24)

        @JvmStatic
        public fun fromOpcode(opcode: Int): BlueLineCommand? = entries.firstOrNull { it.opcode == opcode }
    }
}

/** Control result codes. */
public enum class BlueLineResult(public val code: Int) {
    OK(0),
    NOT_SUPPORTED(1),
    INVALID_PARAM(2),
    INVALID_STATE(3),
    BUSY(4),
    HARDWARE_FAULT(5);

    public companion object {
        @JvmStatic
        public fun fromCode(code: Int): BlueLineResult? = entries.firstOrNull { it.code == code }
    }
}

/** Control notification: `[opcode] [result] [payload...]`. */
public class BlueLineControlResponse private constructor(
    public val opcode: Int,
    public val rawResult: Int,
    public val payload: ByteArray,
) {
    public val result: BlueLineResult? get() = BlueLineResult.fromCode(rawResult)
    public val isOk: Boolean get() = rawResult == BlueLineResult.OK.code

    /** START_SIGNAL: session u16. SET_GAIN: gain u8, session u16. Null otherwise. */
    public val session: Int?
        get() {
            val offset = when (BlueLineCommand.fromOpcode(opcode)) {
                BlueLineCommand.START_SIGNAL -> 0
                BlueLineCommand.SET_GAIN -> 1
                else -> return null
            }
            if (payload.size < offset + 2) return null
            return ByteReader(payload).u16(offset)
        }

    /** True if this notification answers [command] (or is the BUSY answer to any request). */
    public fun answers(command: BlueLineCommand): Boolean =
        opcode == command.opcode || opcode == BlueLineCommand.BUSY_OPCODE

    override fun toString(): String = "BlueLineControlResponse(opcode=$opcode, result=${result ?: rawResult})"

    public companion object {
        @JvmStatic
        public fun parse(data: ByteArray?): BlueLineControlResponse? {
            if (data == null || data.size < 2) return null
            return BlueLineControlResponse(
                opcode = data[0].toInt() and 0xFF,
                rawResult = data[1].toInt() and 0xFF,
                payload = data.copyOfRange(2, data.size),
            )
        }
    }
}
