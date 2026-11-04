package com.blueline.sdk.android

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.ParcelUuid
import com.blueline.sdk.BlueLineAdvertisement
import com.blueline.sdk.BlueLineException
import com.blueline.sdk.BlueLineV1
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.callbackFlow

/** Bluetooth adapter state as seen by the SDK. */
enum class BluetoothState { UNSUPPORTED, OFF, TURNING_ON, ON, TURNING_OFF }

/** A BlueLine device seen while scanning. */
data class BlueLineDiscovery(
    val device: BluetoothDevice,
    /** MAC address; stable for BlueLine (static random address). */
    val address: String,
    val name: String,
    val rssi: Int,
    /** Model and chip id from the scan response, when present. */
    val advertisement: BlueLineAdvertisement?,
)

/**
 * Finds BlueLine devices and opens connections. Create one per app (or per
 * screen) and call [close] when done.
 *
 * Scanning and connecting need the runtime permissions in [BlueLinePermissions]
 * and Bluetooth switched on ([bluetoothState]).
 */
@SuppressLint("MissingPermission") // checked at runtime; see BlueLinePermissions
class BlueLineScanner(context: Context) : AutoCloseable {
    private val context: Context = context.applicationContext
    private val adapter: BluetoothAdapter? =
        (this.context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private val _bluetoothState = MutableStateFlow(currentState())

    /** Updates when Bluetooth is switched on or off. */
    val bluetoothState: StateFlow<BluetoothState> = _bluetoothState.asStateFlow()

    private val stateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            _bluetoothState.value = currentState()
        }
    }

    init {
        if (adapter != null) {
            // ACTION_STATE_CHANGED is a protected system broadcast: no export flag needed.
            this.context.registerReceiver(stateReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
        }
    }

    private fun currentState(): BluetoothState = when (adapter?.state) {
        null -> BluetoothState.UNSUPPORTED
        BluetoothAdapter.STATE_ON -> BluetoothState.ON
        BluetoothAdapter.STATE_TURNING_ON -> BluetoothState.TURNING_ON
        BluetoothAdapter.STATE_TURNING_OFF -> BluetoothState.TURNING_OFF
        else -> BluetoothState.OFF
    }

    private fun requireReady(forScan: Boolean): BluetoothAdapter {
        val adapter = adapter ?: throw BlueLineException.BluetoothUnavailable("this device has no Bluetooth")
        if (forScan && !BlueLinePermissions.hasAll(context)) {
            throw BlueLineException.BluetoothUnavailable("missing permissions ${BlueLinePermissions.missing(context)}")
        }
        if (!forScan && !BlueLinePermissions.canConnect(context)) {
            throw BlueLineException.BluetoothUnavailable("missing permission BLUETOOTH_CONNECT")
        }
        if (!adapter.isEnabled) throw BlueLineException.BluetoothUnavailable("Bluetooth is off")
        return adapter
    }

    /**
     * Scans for the BlueLine service while the flow is collected. Emits each device
     * once, or on every advertisement with [allowDuplicates] (for live RSSI).
     * The flow fails with [BlueLineException] if scanning cannot start.
     */
    fun scan(allowDuplicates: Boolean = false): Flow<BlueLineDiscovery> = callbackFlow {
        val scanner = requireReady(forScan = true).bluetoothLeScanner
            ?: throw BlueLineException.BluetoothUnavailable("Bluetooth is off")
        val seen = HashSet<String>()
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val address = result.device.address
                if (!allowDuplicates && !seen.add(address)) return
                val record = result.scanRecord
                val payload = record?.getManufacturerSpecificData(BlueLineV1.COMPANY_ID)
                trySend(
                    BlueLineDiscovery(
                        device = result.device,
                        address = address,
                        name = record?.deviceName ?: result.device.name ?: "BlueLine",
                        rssi = result.rssi,
                        advertisement = BlueLineAdvertisement.fromCompanyPayload(payload),
                    ),
                )
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach { onScanResult(ScanSettings.CALLBACK_TYPE_ALL_MATCHES, it) }
            }

            override fun onScanFailed(errorCode: Int) {
                close(BlueLineException.BluetoothUnavailable("scan failed with error $errorCode"))
            }
        }
        val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(BlueLineV1.SERVICE)).build())
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY) // active scan: the service UUID is in the scan response
            .build()
        scanner.startScan(filters, settings, callback)
        awaitClose {
            // stopScan throws if Bluetooth was switched off meanwhile.
            runCatching { if (adapter?.isEnabled == true) scanner.stopScan(callback) }
        }
    }

    /**
     * Connects, requests MTU 247 and high connection priority, reads Info and the
     * device information, and enables notifications. The returned device is
     * ready for `startSignal()`. Retries the common Android GATT error 133 twice.
     */
    suspend fun connect(discovery: BlueLineDiscovery, timeoutMillis: Long = 15_000): BlueLineDevice =
        connect(discovery.device, discovery.name, timeoutMillis)

    /** Connects by MAC address (for example one saved from an earlier scan). */
    suspend fun connect(address: String, timeoutMillis: Long = 15_000): BlueLineDevice {
        val adapter = requireReady(forScan = false)
        if (!BluetoothAdapter.checkBluetoothAddress(address)) {
            throw BlueLineException.InvalidParameter("not a Bluetooth address: $address")
        }
        val device = adapter.getRemoteDevice(address)
        return connect(device, device.name ?: "BlueLine", timeoutMillis)
    }

    private suspend fun connect(device: BluetoothDevice, name: String, timeoutMillis: Long): BlueLineDevice {
        requireReady(forScan = false)
        return BlueLineDevice.open(context, device, name, timeoutMillis)
    }

    /** Unregisters the Bluetooth state receiver. Connected devices stay connected. */
    override fun close() {
        if (adapter != null) runCatching { context.unregisterReceiver(stateReceiver) }
    }
}
