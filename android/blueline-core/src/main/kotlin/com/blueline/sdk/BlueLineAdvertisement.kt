package com.blueline.sdk

/**
 * Manufacturer data in the scan response: company 0xFFFF, then
 * `'B' 'L' model(u8) chip_id_low(u32)`.
 */
public data class BlueLineAdvertisement(
    /** Model number, e.g. 4 = BlueLine-4. */
    val model: Int,
    /** Bits 0..31 of the chip id: tells devices apart before connecting. */
    val chipIdLow: Long,
) {
    public companion object {
        private const val B = 'B'.code
        private const val L = 'L'.code

        /**
         * Parses the payload that follows the company id, as returned by Android's
         * `ScanRecord.getManufacturerSpecificData(0xFFFF)`.
         */
        @JvmStatic
        public fun fromCompanyPayload(payload: ByteArray?): BlueLineAdvertisement? {
            if (payload == null || payload.size < 7) return null
            val r = ByteReader(payload)
            if (r.u8(0) != B || r.u8(1) != L) return null
            return BlueLineAdvertisement(model = r.u8(2), chipIdLow = r.u32(3))
        }

        /** Parses full manufacturer data including the 2-byte company id (as on iOS). */
        @JvmStatic
        public fun fromManufacturerData(data: ByteArray?): BlueLineAdvertisement? {
            if (data == null || data.size < 9) return null
            val r = ByteReader(data)
            if (r.u16(0) != BlueLineV1.COMPANY_ID) return null
            return fromCompanyPayload(data.copyOfRange(2, data.size))
        }
    }
}
