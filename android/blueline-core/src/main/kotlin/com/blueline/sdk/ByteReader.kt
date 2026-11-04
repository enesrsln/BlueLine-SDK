package com.blueline.sdk

/** Little-endian reader. Callers check the length before reading. */
internal class ByteReader(private val bytes: ByteArray) {
    val size: Int get() = bytes.size

    fun u8(offset: Int): Int = bytes[offset].toInt() and 0xFF

    fun u16(offset: Int): Int = u8(offset) or (u8(offset + 1) shl 8)

    /** Unsigned 32-bit value in a Long (0..4294967295). */
    fun u32(offset: Int): Long =
        (0 until 4).fold(0L) { acc, i -> acc or (u8(offset + i).toLong() shl (8 * i)) }

    /** 64-bit value as a Long bit pattern (may be negative). */
    fun u64(offset: Int): Long =
        (0 until 8).fold(0L) { acc, i -> acc or (u8(offset + i).toLong() shl (8 * i)) }

    fun i16(offset: Int): Int = u16(offset).toShort().toInt()

    /** Signed 24-bit big-endian (ADS1299 native). */
    fun int24BE(offset: Int): Int {
        val raw = (u8(offset) shl 16) or (u8(offset + 1) shl 8) or u8(offset + 2)
        return (raw shl 8) shr 8
    }
}

internal const val U32_MASK: Long = 0xFFFF_FFFFL
