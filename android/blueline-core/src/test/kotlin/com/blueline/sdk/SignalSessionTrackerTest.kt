package com.blueline.sdk

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SignalSessionTrackerTest {
    /** A 1-channel packet with [count] zero samples. */
    private fun packet(session: Int, firstIndex: Long, count: Int = 5, firmwareGap: Boolean = false): ByteArray {
        val bytes = ByteArray(8 + count * 3)
        bytes[0] = if (firmwareGap) 1 else 0
        bytes[1] = count.toByte()
        bytes[2] = (session and 0xFF).toByte(); bytes[3] = (session shr 8).toByte()
        for (i in 0 until 4) bytes[4 + i] = (firstIndex shr (8 * i)).toByte()
        return bytes
    }

    @Test
    fun dropsPacketsBeforeBeginAndOfOtherSessions() {
        val tracker = SignalSessionTracker(channelCount = 1)
        assertNull(tracker.accept(packet(1, 0)))
        tracker.begin(session = 2, microvoltsPerCount = 0.5)
        assertNull(tracker.accept(packet(1, 0)))
        val p = assertNotNull(tracker.accept(packet(2, 0)))
        assertEquals(0.5, p.microvoltsPerCount)
        tracker.end()
        assertNull(tracker.accept(packet(2, 5)))
    }

    @Test
    fun marksGapWhenIndexDoesNotContinue() {
        val tracker = SignalSessionTracker(1).apply { begin(7, 1.0) }
        assertFalse(tracker.accept(packet(7, 0))!!.gapBefore)
        assertFalse(tracker.accept(packet(7, 5))!!.gapBefore)
        assertTrue(tracker.accept(packet(7, 15))!!.gapBefore) // 10..14 lost
        assertFalse(tracker.accept(packet(7, 20))!!.gapBefore)
    }

    @Test
    fun keepsFirmwareAndAppGaps() {
        val tracker = SignalSessionTracker(1).apply { begin(1, 1.0) }
        assertTrue(tracker.accept(packet(1, 0, firmwareGap = true))!!.gapBefore)
        tracker.markGap()
        assertTrue(tracker.accept(packet(1, 5))!!.gapBefore)
        assertFalse(tracker.accept(packet(1, 10))!!.gapBefore)
    }

    @Test
    fun indexWrapsAt32Bits() {
        val tracker = SignalSessionTracker(1).apply { begin(1, 1.0) }
        tracker.accept(packet(1, 0xFFFF_FFFDL, count = 3))
        assertFalse(tracker.accept(packet(1, 0))!!.gapBefore)
    }

    @Test
    fun beginResetsIndexTracking() {
        val tracker = SignalSessionTracker(1).apply { begin(1, 1.0) }
        tracker.accept(packet(1, 100))
        tracker.begin(2, 2.0)
        assertFalse(tracker.accept(packet(2, 0))!!.gapBefore)
    }

    @Test
    fun microvoltsUseSessionScale() {
        val bytes = packet(3, 0, count = 1).also { it[8] = 0xFF.toByte(); it[9] = 0xFF.toByte(); it[10] = 0xFE.toByte() } // -2
        val p = SignalSessionTracker(1).apply { begin(3, 0.25) }.accept(bytes)!!
        assertEquals(-2, p.samples[0][0])
        assertEquals(-0.5, p.microvolts[0][0])
    }
}
