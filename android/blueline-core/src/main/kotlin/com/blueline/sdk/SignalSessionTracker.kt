package com.blueline.sdk

/**
 * Turns raw Signal notifications into packets of the active session:
 * drops packets of other sessions, marks gaps when the sample index does not
 * continue, and attaches the session's microvolt scale.
 *
 * `BlueLineDevice` uses one internally; it is public so recorded notifications
 * can be replayed through the same logic. Thread-safe.
 */
public class SignalSessionTracker(private val channelCount: Int) {
    private var session: Int? = null
    private var microvoltsPerCount = 0.0
    private var nextIndex: Long? = null
    private var pendingGap = false

    /** Session of the running acquisition; null while the signal is stopped. */
    @get:Synchronized
    public val activeSession: Int? get() = session

    /** Starts accepting packets of [session]; sample indices restart. */
    @Synchronized
    public fun begin(session: Int, microvoltsPerCount: Double) {
        this.session = session
        this.microvoltsPerCount = microvoltsPerCount
        nextIndex = null
        pendingGap = false
    }

    /** Stops accepting packets. */
    @Synchronized
    public fun end() {
        session = null
        nextIndex = null
        pendingGap = false
    }

    /** The next accepted packet gets `gapBefore = true` (for packets the app could not take). */
    @Synchronized
    public fun markGap() {
        if (session != null) pendingGap = true
    }

    /** Returns the packet if it belongs to the active session, else null. */
    @Synchronized
    public fun accept(data: ByteArray?): BlueLineSignalPacket? {
        val active = session ?: return null
        val packet = BlueLineSignalPacket.parse(data, channelCount) ?: return null
        if (packet.session != active) return null
        val expected = nextIndex
        val gap = packet.gapBefore || pendingGap || (expected != null && expected != packet.firstIndex)
        pendingGap = false
        nextIndex = packet.nextIndex
        return packet.with(gapBefore = gap, microvoltsPerCount = microvoltsPerCount)
    }
}
