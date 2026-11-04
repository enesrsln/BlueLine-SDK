package com.blueline.sdk.android

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.content.Context
import android.os.Build
import com.blueline.sdk.BlueLineCommand
import com.blueline.sdk.BlueLineControlResponse
import com.blueline.sdk.BlueLineException
import com.blueline.sdk.BlueLineFeature
import com.blueline.sdk.BlueLineInfo
import com.blueline.sdk.BlueLineMemsSample
import com.blueline.sdk.BlueLineSignalPacket
import com.blueline.sdk.BlueLineStatus
import com.blueline.sdk.BlueLineV1
import com.blueline.sdk.SignalSessionTracker
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** Connection state of a [BlueLineDevice]. */
sealed interface ConnectionState {
    data object Connecting : ConnectionState
    data object Connected : ConnectionState

    /** [error] is null after [BlueLineDevice.disconnect] or [BlueLineDevice.close]. */
    data class Disconnected(val error: Throwable?) : ConnectionState
}

/**
 * A connected BlueLine device, obtained from [BlueLineScanner.connect].
 *
 * Commands are `suspend` functions and may be called from any coroutine; they run
 * one at a time (the firmware rejects overlapping requests). Failures throw
 * [BlueLineException]. Data arrives on [signal], [mems], [status] and [batteryLevel].
 * Collect [signal] promptly: if the app falls more than [SIGNAL_BUFFER] packets
 * (about 10 s) behind, packets are dropped and the next one has `gapBefore = true`.
 */
@SuppressLint("MissingPermission") // BLUETOOTH_CONNECT is checked by BlueLineScanner.connect
class BlueLineDevice private constructor(
    private val context: Context,
    /** The Android device behind this connection. */
    val bluetoothDevice: BluetoothDevice,
    val name: String,
) : AutoCloseable {

    val address: String get() = bluetoothDevice.address

    @Volatile private var _info: BlueLineInfo? = null

    /** Read during connection; `gain` follows [setGain]. */
    val info: BlueLineInfo get() = _info ?: throw BlueLineException.NotConnected()

    /** Device Information serial: the factory serial, or the chip id as 16 hex characters. */
    @Volatile var serialNumber: String? = null
        private set

    @Volatile var firmwareRevision: String? = null
        private set

    /** Negotiated ATT MTU (23 until the MTU exchange succeeds). */
    @Volatile var mtu: Int = 23
        private set

    /** Session of the running acquisition; null while the signal is stopped. */
    val session: Int? get() = tracker?.activeSession

    private val _connectionState = MutableStateFlow<ConnectionState>(ConnectionState.Connecting)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    val isConnected: Boolean get() = _connectionState.value == ConnectionState.Connected

    private val _signal = MutableSharedFlow<BlueLineSignalPacket>(
        extraBufferCapacity = SIGNAL_BUFFER, onBufferOverflow = BufferOverflow.SUSPEND,
    )

    /** EEG packets of the current session (about every 20 ms, 5 samples at 250 Hz). */
    val signal: SharedFlow<BlueLineSignalPacket> = _signal.asSharedFlow()

    private val _mems = MutableSharedFlow<BlueLineMemsSample>(
        extraBufferCapacity = MEMS_BUFFER, onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    /** Accelerometer samples (100 Hz) after [startMems]. */
    val mems: SharedFlow<BlueLineMemsSample> = _mems.asSharedFlow()

    private val _status = MutableStateFlow<BlueLineStatus?>(null)

    /** State, gain and loss counters (counter-only changes at most once per second). */
    val status: StateFlow<BlueLineStatus?> = _status.asStateFlow()

    private val _batteryLevel = MutableStateFlow<Int?>(null)
    val batteryLevel: StateFlow<Int?> = _batteryLevel.asStateFlow()

    // ------------------------------------------------------------------ commands

    /**
     * Starts EEG acquisition and returns the new session. If already streaming the
     * device keeps the current session and returns it. Sample indices restart at 0.
     */
    suspend fun startSignal(): Int {
        val response = send(BlueLineCommand.START_SIGNAL)
        return response.session ?: throw BlueLineException.CommandFailed(
            BlueLineCommand.START_SIGNAL, response.result, response.rawResult,
        )
    }

    suspend fun stopSignal() {
        send(BlueLineCommand.STOP_SIGNAL)
    }

    /** Starts the accelerometer stream ([mems]). */
    suspend fun startMems() {
        requireFeature(BlueLineFeature.MEMS)
        send(BlueLineCommand.START_MEMS)
    }

    suspend fun stopMems() {
        send(BlueLineCommand.STOP_MEMS)
    }

    /**
     * Sets the PGA gain (1, 2, 4, 6, 8, 12 or 24; 6 after every boot). While
     * streaming this restarts acquisition: a new session starts and the sample index
     * restarts at 0. Never mix samples of different sessions. Returns the session.
     */
    suspend fun setGain(gain: Int): Int {
        if (gain !in BlueLineCommand.SUPPORTED_GAINS) {
            throw BlueLineException.InvalidParameter("gain $gain not in ${BlueLineCommand.SUPPORTED_GAINS}")
        }
        requireFeature(BlueLineFeature.SET_GAIN)
        val response = send(BlueLineCommand.SET_GAIN, gain)
        return response.session ?: throw BlueLineException.CommandFailed(
            BlueLineCommand.SET_GAIN, response.result, response.rawResult,
        )
    }

    /** Blinks the device LED green for 2 seconds. */
    suspend fun identify() {
        requireFeature(BlueLineFeature.IDENTIFY)
        send(BlueLineCommand.IDENTIFY)
    }

    /** Stops acquisition (STOP_SIGNAL) and closes the connection. */
    suspend fun disconnect() {
        if (gatt == null) return
        if (session != null) {
            try {
                send(BlueLineCommand.STOP_SIGNAL, timeoutMillis = 1_000)
            } catch (_: BlueLineException) {
                // Disconnecting stops acquisition on the device anyway.
            }
        }
        userDisconnect = true
        val waiter = disconnected
        gatt?.disconnect()
        withTimeoutOrNull(2_000) { waiter.await() }
        handleDisconnect(gatt, null) // no-op if the callback already came
    }

    /**
     * Closes the connection immediately, without STOP_SIGNAL (the firmware stops
     * acquisition when the link drops). Use from non-suspending code, for example
     * `ViewModel.onCleared()`.
     */
    override fun close() {
        userDisconnect = true
        val g = gatt ?: return
        runCatching { g.disconnect() }
        handleDisconnect(g, null)
    }

    private fun requireFeature(feature: BlueLineFeature) {
        if (!info.supports(feature)) {
            throw BlueLineException.UnsupportedDevice("feature $feature not supported by firmware ${info.firmwareVersion}")
        }
    }

    // ------------------------------------------------------------------ control channel

    private class PendingControl(
        val command: BlueLineCommand,
        val response: CompletableDeferred<BlueLineControlResponse> = CompletableDeferred(),
    )

    private val controlMutex = Mutex()
    @Volatile private var pendingControl: PendingControl? = null

    private suspend fun send(
        command: BlueLineCommand,
        vararg params: Int,
        timeoutMillis: Long = 3_000,
    ): BlueLineControlResponse = controlMutex.withLock {
        if (!isConnected) throw BlueLineException.NotConnected()
        val pending = PendingControl(command)
        pendingControl = pending
        try {
            write(BlueLineV1.CONTROL, command.request(*params))
            val response = withTimeoutOrNull(timeoutMillis) { pending.response.await() }
                ?: throw BlueLineException.Timeout(command.name)
            if (!response.isOk) throw BlueLineException.CommandFailed(command, response.result, response.rawResult)
            response
        } finally {
            pendingControl = null
        }
    }

    /**
     * Runs on the Bluetooth callback thread, before the command's caller resumes,
     * so no Signal packet of a new session is dropped in between.
     */
    private fun onControlResponse(command: BlueLineCommand, response: BlueLineControlResponse) {
        if (!response.isOk) return
        val tracker = tracker ?: return
        when (command) {
            BlueLineCommand.START_SIGNAL -> response.session?.let { tracker.begin(it, info.microvoltsPerCount) }
            BlueLineCommand.STOP_SIGNAL -> tracker.end()
            BlueLineCommand.SET_GAIN -> {
                val newGain = response.payload.firstOrNull()?.toInt()?.and(0xFF)
                if (newGain != null && newGain > 0) _info = info.copy(gain = newGain)
                if (tracker.activeSession != null) {
                    response.session?.let { tracker.begin(it, info.microvoltsPerCount) }
                }
            }
            else -> Unit
        }
    }

    // ------------------------------------------------------------------ GATT plumbing

    @Volatile private var gatt: BluetoothGatt? = null
    @Volatile private var tracker: SignalSessionTracker? = null
    @Volatile private var userDisconnect = false
    @Volatile private var connected: CompletableDeferred<Unit> = CompletableDeferred()
    @Volatile private var disconnected: CompletableDeferred<Unit> = CompletableDeferred()
    private val characteristics = ConcurrentHashMap<UUID, BluetoothGattCharacteristic>()

    private enum class Op { MTU, DISCOVER, READ, WRITE, ENABLE_NOTIFY }

    private class PendingOp(val op: Op, val uuid: UUID?, val result: CompletableDeferred<Any?> = CompletableDeferred())

    /** Wraps a possibly-null result so withTimeoutOrNull can tell "null" from "timed out". */
    private class Box(val value: Any?)

    private val opMutex = Mutex()
    @Volatile private var pendingOp: PendingOp? = null

    /** Android allows one outstanding GATT operation per connection: run them one at a time. */
    private suspend fun gattOp(
        op: Op,
        uuid: UUID?,
        timeoutMillis: Long = 5_000,
        start: (BluetoothGatt) -> Boolean,
    ): Any? = opMutex.withLock {
        val g = gatt ?: throw BlueLineException.NotConnected()
        val pending = PendingOp(op, uuid)
        pendingOp = pending
        try {
            if (!start(g)) throw BlueLineException.ConnectionFailed("$op could not be started")
            val box = withTimeoutOrNull(timeoutMillis) { Box(pending.result.await()) }
                ?: throw BlueLineException.Timeout(op.name.lowercase())
            box.value
        } finally {
            pendingOp = null
        }
    }

    private fun completeOp(op: Op, uuid: UUID?, status: Int, value: Any?) {
        val pending = pendingOp ?: return
        if (pending.op != op || (uuid != null && pending.uuid != uuid)) return
        if (status == BluetoothGatt.GATT_SUCCESS) {
            pending.result.complete(value)
        } else {
            pending.result.completeExceptionally(BlueLineException.ConnectionFailed("$op failed", status))
        }
    }

    private fun characteristic(uuid: UUID): BluetoothGattCharacteristic =
        characteristics[uuid] ?: throw BlueLineException.UnsupportedDevice("characteristic $uuid missing")

    private suspend fun read(uuid: UUID): ByteArray {
        val c = characteristic(uuid)
        return gattOp(Op.READ, uuid) { it.readCharacteristic(c) } as? ByteArray ?: ByteArray(0)
    }

    private suspend fun write(uuid: UUID, value: ByteArray) {
        val c = characteristic(uuid)
        gattOp(Op.WRITE, uuid) { g ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                g.writeCharacteristic(c, value, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) ==
                    BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                @Suppress("DEPRECATION")
                c.value = value
                @Suppress("DEPRECATION")
                g.writeCharacteristic(c)
            }
        }
    }

    private suspend fun enableNotifications(uuid: UUID) {
        val c = characteristic(uuid)
        val descriptor = c.getDescriptor(BlueLineV1.CCCD)
            ?: throw BlueLineException.UnsupportedDevice("characteristic $uuid has no CCCD")
        gattOp(Op.ENABLE_NOTIFY, uuid) { g ->
            if (!g.setCharacteristicNotification(c, true)) return@gattOp false
            val enable = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                g.writeDescriptor(descriptor, enable) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                descriptor.value = enable
                @Suppress("DEPRECATION")
                g.writeDescriptor(descriptor)
            }
        }
    }

    // ------------------------------------------------------------------ connection setup

    private suspend fun establish() {
        var attempt = 0
        while (true) {
            userDisconnect = false
            connected = CompletableDeferred()
            disconnected = CompletableDeferred()
            _connectionState.value = ConnectionState.Connecting
            gatt = bluetoothDevice.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
                ?: throw BlueLineException.ConnectionFailed("connectGatt returned null")
            try {
                connected.await()
                break
            } catch (e: BlueLineException.ConnectionFailed) {
                closeGatt()
                // 133 (GATT_ERROR) is Android's generic "could not connect"; a retry usually works.
                if (e.gattStatus == GATT_ERROR && attempt < CONNECT_RETRIES) {
                    attempt++
                    delay(600)
                    continue
                }
                throw e
            }
        }

        mtu = try {
            gattOp(Op.MTU, null) { it.requestMtu(BlueLineV1.PREFERRED_MTU) } as Int
        } catch (_: BlueLineException.ConnectionFailed) {
            mtu // the firmware adapts packets to whatever MTU we end up with
        } catch (_: BlueLineException.Timeout) {
            mtu
        }
        gatt?.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH)
        gatt?.setPreferredPhy(BluetoothDevice.PHY_LE_2M_MASK, BluetoothDevice.PHY_LE_2M_MASK, BluetoothDevice.PHY_OPTION_NO_PREFERRED)

        gattOp(Op.DISCOVER, null, timeoutMillis = 10_000) { it.discoverServices() }
        val g = gatt ?: throw BlueLineException.Disconnected()
        val service = g.getService(BlueLineV1.SERVICE)
            ?: throw BlueLineException.UnsupportedDevice("no BlueLine v1 service (firmware < 0.3.0?)")
        for (s in listOfNotNull(service, g.getService(BlueLineV1.BATTERY_SERVICE), g.getService(BlueLineV1.DEVICE_INFORMATION_SERVICE))) {
            s.characteristics.forEach { characteristics[it.uuid] = it }
        }

        val info = BlueLineInfo.parse(read(BlueLineV1.INFO))
            ?: throw BlueLineException.UnsupportedDevice("unreadable Info")
        if (!info.isSupported) {
            throw BlueLineException.UnsupportedDevice("protocol ${info.protocolVersion}, firmware ${info.firmwareVersion}")
        }
        _info = info
        tracker = SignalSessionTracker(info.channelCount)

        serialNumber = readStringOrNull(BlueLineV1.SERIAL_NUMBER)
        firmwareRevision = readStringOrNull(BlueLineV1.FIRMWARE_REVISION)

        enableNotifications(BlueLineV1.CONTROL)
        enableNotifications(BlueLineV1.STATUS)
        enableNotifications(BlueLineV1.SIGNAL)
        if (info.supports(BlueLineFeature.MEMS)) enableNotifications(BlueLineV1.MEMS)
        _status.value = BlueLineStatus.parse(read(BlueLineV1.STATUS))

        if (characteristics.containsKey(BlueLineV1.BATTERY_LEVEL)) {
            try {
                _batteryLevel.value = read(BlueLineV1.BATTERY_LEVEL).firstOrNull()?.toInt()?.and(0xFF)
                enableNotifications(BlueLineV1.BATTERY_LEVEL)
            } catch (_: BlueLineException.ConnectionFailed) {
                // Battery is optional; Status also reports it.
            }
        }

        _connectionState.value = ConnectionState.Connected
    }

    private suspend fun readStringOrNull(uuid: UUID): String? {
        if (!characteristics.containsKey(uuid)) return null
        return try {
            read(uuid).toString(Charsets.UTF_8).trimEnd('\u0000')
        } catch (_: BlueLineException.ConnectionFailed) {
            null
        }
    }

    private fun closeGatt() {
        val g = gatt ?: return
        gatt = null
        runCatching { g.close() }
    }

    /** Idempotent: tears the connection down once per [BluetoothGatt]. */
    private fun handleDisconnect(from: BluetoothGatt?, error: Throwable?) {
        synchronized(this) {
            if (from == null || from !== gatt) return
            closeGatt()
        }
        tracker?.end()
        pendingOp?.result?.completeExceptionally(BlueLineException.Disconnected())
        pendingControl?.response?.completeExceptionally(BlueLineException.Disconnected())
        _connectionState.value = ConnectionState.Disconnected(if (userDisconnect) null else error)
        disconnected.complete(Unit)
    }

    private fun handleNotification(uuid: UUID, value: ByteArray) {
        when (uuid) {
            BlueLineV1.SIGNAL -> {
                val tracker = tracker ?: return
                val packet = tracker.accept(value) ?: return
                if (!_signal.tryEmit(packet)) tracker.markGap()
            }
            BlueLineV1.MEMS -> {
                val sample = BlueLineMemsSample.parse(value) ?: return
                val active = session
                if (active == null || sample.session == active) _mems.tryEmit(sample)
            }
            BlueLineV1.CONTROL -> {
                val response = BlueLineControlResponse.parse(value) ?: return
                val pending = pendingControl ?: return
                if (!response.answers(pending.command)) return
                onControlResponse(pending.command, response)
                pending.response.complete(response)
            }
            BlueLineV1.STATUS -> BlueLineStatus.parse(value)?.let { _status.value = it }
            BlueLineV1.BATTERY_LEVEL -> value.firstOrNull()?.let { _batteryLevel.value = it.toInt() and 0xFF }
        }
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (g !== gatt) return
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                connected.complete(Unit)
                return
            }
            if (newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) {
                if (!connected.isCompleted) {
                    // Still connecting: let establish() decide whether to retry.
                    connected.completeExceptionally(BlueLineException.ConnectionFailed("could not connect", status))
                    return
                }
                val error = if (status == BluetoothGatt.GATT_SUCCESS) null else BlueLineException.ConnectionFailed("link lost", status)
                handleDisconnect(g, error ?: BlueLineException.Disconnected())
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            if (g !== gatt) return
            if (status == BluetoothGatt.GATT_SUCCESS) this@BlueLineDevice.mtu = mtu
            completeOp(Op.MTU, null, status, mtu)
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            if (g === gatt) completeOp(Op.DISCOVER, null, status, null)
        }

        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            if (g === gatt) completeOp(Op.READ, c.uuid, status, value)
        }

        @Deprecated("Called below Android 13 only")
        @Suppress("DEPRECATION")
        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            if (g === gatt) completeOp(Op.READ, c.uuid, status, c.value?.copyOf())
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            if (g === gatt) completeOp(Op.WRITE, c.uuid, status, null)
        }

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) {
            if (g === gatt) completeOp(Op.ENABLE_NOTIFY, d.characteristic.uuid, status, null)
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) {
            if (g === gatt) handleNotification(c.uuid, value)
        }

        @Deprecated("Called below Android 13 only")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            if (g === gatt) c.value?.copyOf()?.let { handleNotification(c.uuid, it) }
        }
    }

    companion object {
        /** Signal packets buffered for slow collectors (~10 s at 50 packets/s). */
        const val SIGNAL_BUFFER: Int = 512
        private const val MEMS_BUFFER = 256
        private const val GATT_ERROR = 133
        private const val CONNECT_RETRIES = 2

        internal suspend fun open(
            context: Context,
            device: BluetoothDevice,
            name: String,
            timeoutMillis: Long,
        ): BlueLineDevice {
            val blueLine = BlueLineDevice(context, device, name)
            try {
                withTimeout(timeoutMillis) { blueLine.establish() }
            } catch (e: TimeoutCancellationException) {
                blueLine.close()
                throw BlueLineException.Timeout("connect")
            } catch (e: Throwable) {
                blueLine.close()
                throw e
            }
            return blueLine
        }
    }
}
