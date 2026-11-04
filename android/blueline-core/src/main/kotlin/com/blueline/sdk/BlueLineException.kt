package com.blueline.sdk

/** Every failure of the SDK is a subclass of this exception. */
public sealed class BlueLineException(message: String, cause: Throwable? = null) : RuntimeException(message, cause) {

    /** Bluetooth is off, missing, or a runtime permission was not granted. */
    public class BluetoothUnavailable(public val reason: String) :
        BlueLineException("Bluetooth is not available: $reason.")

    /** Connecting or a GATT operation failed. [gattStatus] is the Android GATT status, if any. */
    public class ConnectionFailed(public val detail: String, public val gattStatus: Int? = null, cause: Throwable? = null) :
        BlueLineException(
            "Connection failed: $detail" + (gattStatus?.let { " (GATT status $it)" } ?: "") + ".",
            cause,
        )

    /** The device does not speak BlueLine protocol v1 (firmware < 0.3.0). */
    public class UnsupportedDevice(public val reason: String) :
        BlueLineException("Unsupported BlueLine device: $reason.")

    public class Timeout(what: String) : BlueLineException("The BlueLine device did not respond in time ($what).")

    public class NotConnected : BlueLineException("The BlueLine device is not connected.")

    /** The connection dropped while a request was pending. */
    public class Disconnected : BlueLineException("The BlueLine device disconnected.")

    public class InvalidParameter(public val reason: String) : BlueLineException("Invalid parameter: $reason.")

    /** The device answered a control request with an error result. */
    public class CommandFailed(public val command: BlueLineCommand, public val result: BlueLineResult?, public val rawResult: Int) :
        BlueLineException("Command $command failed (${result ?: "result $rawResult"}).")
}
