package com.blueline.sdk.android

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

/**
 * Runtime permissions needed to scan and connect. Request [required] with
 * `ActivityResultContracts.RequestMultiplePermissions` before using the scanner:
 *
 * ```
 * val launcher = registerForActivityResult(RequestMultiplePermissions()) { granted -> ... }
 * if (!BlueLinePermissions.hasAll(this)) launcher.launch(BlueLinePermissions.required())
 * ```
 */
object BlueLinePermissions {
    /** Android 12+: BLUETOOTH_SCAN and BLUETOOTH_CONNECT. Android 8-11: ACCESS_FINE_LOCATION. */
    @JvmStatic
    fun required(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    @JvmStatic
    fun missing(context: Context): List<String> =
        required().filter { context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }

    @JvmStatic
    fun hasAll(context: Context): Boolean = missing(context).isEmpty()

    /** Connecting (and reading GATT) needs BLUETOOTH_CONNECT on Android 12+; nothing extra before. */
    internal fun canConnect(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
}
