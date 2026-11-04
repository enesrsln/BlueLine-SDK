package com.blueline.sdk

import java.util.UUID

/**
 * UUIDs and constants of BlueLine BLE protocol v1 (BlueLine devices, firmware >= 0.3.0).
 *
 * Multi-byte fields are little-endian, except EEG samples, which are signed
 * 24-bit big-endian (ADS1299 native).
 */
public object BlueLineV1 {
    public const val PROTOCOL_VERSION: Int = 1

    public val SERVICE: UUID = UUID.fromString("8E7C0001-7B4E-4C1E-AF19-22A6F38D9B40")
    public val INFO: UUID = UUID.fromString("8E7C0002-7B4E-4C1E-AF19-22A6F38D9B40")
    public val SIGNAL: UUID = UUID.fromString("8E7C0003-7B4E-4C1E-AF19-22A6F38D9B40")
    public val MEMS: UUID = UUID.fromString("8E7C0004-7B4E-4C1E-AF19-22A6F38D9B40")
    public val STATUS: UUID = UUID.fromString("8E7C0005-7B4E-4C1E-AF19-22A6F38D9B40")
    public val CONTROL: UUID = UUID.fromString("8E7C0006-7B4E-4C1E-AF19-22A6F38D9B40")

    public val BATTERY_SERVICE: UUID = bluetoothUuid(0x180F)
    public val BATTERY_LEVEL: UUID = bluetoothUuid(0x2A19)
    public val DEVICE_INFORMATION_SERVICE: UUID = bluetoothUuid(0x180A)
    public val SERIAL_NUMBER: UUID = bluetoothUuid(0x2A25)
    public val FIRMWARE_REVISION: UUID = bluetoothUuid(0x2A26)

    /** Client Characteristic Configuration descriptor (enables notifications). */
    public val CCCD: UUID = bluetoothUuid(0x2902)

    /** Company id of the manufacturer data in the scan response. */
    public const val COMPANY_ID: Int = 0xFFFF

    /** ATT MTU to request after connecting (the firmware supports 247). */
    public const val PREFERRED_MTU: Int = 247

    internal const val SIGNAL_HEADER_BYTES: Int = 8
    internal const val BYTES_PER_CHANNEL_SAMPLE: Int = 3

    private fun bluetoothUuid(short: Int): UUID =
        UUID.fromString(String.format("%08X-0000-1000-8000-00805F9B34FB", short))
}
