//
//  BlueLineProtocol.swift
//  BlueLineSDK
//
//  BlueLine BLE protocol v1 (BlueLine devices, firmware >= 0.3.0): UUIDs and
//  packet parsers. Pure value types with no CoreBluetooth state, so they can
//  also be used to decode recorded packets. Multi-byte fields are
//  little-endian, except EEG samples, which are signed 24-bit big-endian.
//

import Foundation
import CoreBluetooth

/// UUIDs and constants of BlueLine protocol v1.
public enum BlueLineV1 {
    public static let protocolVersion = 1

    public static let service = CBUUID(string: "8E7C0001-7B4E-4C1E-AF19-22A6F38D9B40")
    public static let info    = CBUUID(string: "8E7C0002-7B4E-4C1E-AF19-22A6F38D9B40")
    public static let signal  = CBUUID(string: "8E7C0003-7B4E-4C1E-AF19-22A6F38D9B40")
    public static let mems    = CBUUID(string: "8E7C0004-7B4E-4C1E-AF19-22A6F38D9B40")
    public static let status  = CBUUID(string: "8E7C0005-7B4E-4C1E-AF19-22A6F38D9B40")
    public static let control = CBUUID(string: "8E7C0006-7B4E-4C1E-AF19-22A6F38D9B40")

    public static let batteryService           = CBUUID(string: "180F")
    public static let batteryLevel             = CBUUID(string: "2A19")
    public static let deviceInformationService = CBUUID(string: "180A")
    public static let serialNumber             = CBUUID(string: "2A25")
    public static let firmwareRevision         = CBUUID(string: "2A26")

    static let signalHeaderBytes = 8
    static let bytesPerChannelSample = 3
}

// MARK: - Byte helpers

/// Bounds-checked little-endian reader over a zero-based byte copy.
struct ByteReader {
    let bytes: [UInt8]
    init(_ data: Data) { bytes = [UInt8](data) }

    func u8(_ offset: Int) -> UInt8 { bytes[offset] }
    func u16(_ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    func u32(_ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
    func u64(_ offset: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * $1) }
    }
    /// Signed 24-bit big-endian (ADS1299 native).
    func int24BE(_ offset: Int) -> Int32 {
        var raw = UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2])
        if raw & 0x0080_0000 != 0 { raw |= 0xFF00_0000 }
        return Int32(bitPattern: raw)
    }
}

// MARK: - Advertisement

/// Manufacturer data in the scan response: company 0xFFFF, `'B' 'L' model chip_id_low`.
public struct BlueLineAdvertisement: Equatable, Sendable {
    /// Model number, e.g. 4 = BlueLine-4.
    public let model: Int
    /// Bits 0..31 of the chip id: tells devices apart before connecting.
    public let chipIDLow: UInt32

    public init?(manufacturerData data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 9, bytes[0] == 0xFF, bytes[1] == 0xFF,
              bytes[2] == UInt8(ascii: "B"), bytes[3] == UInt8(ascii: "L") else { return nil }
        let r = ByteReader(data)
        model = Int(r.u8(4))
        chipIDLow = r.u32(5)
    }
}

// MARK: - Info (read, 32 bytes)

/// Static device description read once after connecting.
public struct BlueLineInfo: Equatable, Sendable {
    public struct Features: OptionSet, Equatable, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let signal   = Features(rawValue: 1 << 0)
        public static let mems     = Features(rawValue: 1 << 1)
        public static let resist   = Features(rawValue: 1 << 2)
        public static let identify = Features(rawValue: 1 << 3)
        public static let setGain  = Features(rawValue: 1 << 4)
    }

    static let byteCount = 32

    public let protocolVersion: Int
    public let model: Int
    /// The DIS serial number is a factory serial (otherwise the chip id).
    public let hasFactorySerial: Bool
    public let channelCount: Int
    public let firmwareMajor: Int
    public let firmwareMinor: Int
    public let firmwarePatch: Int
    public let adcBits: Int
    public let adcRateHz: Int
    /// EEG output rate (250 Hz).
    public let signalRateHz: Int
    public let decimation: Int
    /// Current PGA gain; updated by `BlueLineDevice.setGain(_:)`.
    public internal(set) var gain: Int
    public let vrefMicrovolts: UInt32
    public let memsRateHz: Int
    public let maxSamplesPerPacket: Int
    public let signalHeaderBytes: Int
    public let features: Features
    public let chipID: UInt64

    public var firmwareVersion: String { "\(firmwareMajor).\(firmwareMinor).\(firmwarePatch)" }

    /// uV = code * vref_uV / (gain * 2^23)
    public var microvoltsPerCount: Double {
        Double(vrefMicrovolts) / (Double(gain) * 8_388_608.0)
    }

    public init?(_ data: Data) {
        guard data.count >= Self.byteCount else { return nil }
        let r = ByteReader(data)
        protocolVersion = Int(r.u8(0))
        model = Int(r.u8(1))
        hasFactorySerial = r.u8(2) & 0x01 != 0
        channelCount = Int(r.u8(3))
        firmwareMajor = Int(r.u8(4))
        firmwareMinor = Int(r.u8(5))
        firmwarePatch = Int(r.u8(6))
        adcBits = Int(r.u8(7))
        adcRateHz = Int(r.u16(8))
        signalRateHz = Int(r.u16(10))
        decimation = Int(r.u8(12))
        gain = Int(r.u8(13))
        vrefMicrovolts = r.u32(14)
        memsRateHz = Int(r.u16(18))
        maxSamplesPerPacket = Int(r.u8(20))
        signalHeaderBytes = Int(r.u8(21))
        features = Features(rawValue: r.u16(22))
        chipID = r.u64(24)
        guard channelCount > 0, signalRateHz > 0, gain > 0, vrefMicrovolts > 0 else { return nil }
    }

    /// Fields the decoder relies on match this SDK.
    public var isSupported: Bool {
        protocolVersion == BlueLineV1.protocolVersion
            && signalHeaderBytes == BlueLineV1.signalHeaderBytes
            && features.contains(.signal)
    }
}

// MARK: - Signal (notify)

/// One EEG notification: up to 19 consecutive samples of every channel.
public struct BlueLineSignalPacket: Sendable {
    /// Samples before `firstIndex` were lost (firmware flag), or the index
    /// did not continue from the previous packet (set by `BlueLineDevice`).
    public internal(set) var gapBefore: Bool
    public let session: UInt16
    /// Sample index since START_SIGNAL of the first sample; t = index / signalRateHz.
    public let firstIndex: UInt32
    /// Raw ADC counts as [sample][channel].
    public let samples: [[Int32]]
    /// Scale of this packet's session (set by `BlueLineDevice`; 0 if unknown).
    public internal(set) var microvoltsPerCount: Double = 0

    /// Samples in microvolts as [sample][channel].
    public var microvolts: [[Double]] {
        samples.map { $0.map { Double($0) * microvoltsPerCount } }
    }

    public init?(_ data: Data, channelCount: Int) {
        let header = BlueLineV1.signalHeaderBytes
        guard channelCount > 0, data.count > header else { return nil }
        let r = ByteReader(data)
        let count = Int(r.u8(1))
        let stride = channelCount * BlueLineV1.bytesPerChannelSample
        guard count > 0, data.count == header + count * stride else { return nil }
        gapBefore = r.u8(0) & 0x01 != 0
        session = r.u16(2)
        firstIndex = r.u32(4)
        samples = (0..<count).map { sample in
            (0..<channelCount).map { r.int24BE(header + sample * stride + $0 * BlueLineV1.bytesPerChannelSample) }
        }
    }
}

// MARK: - MEMS (notify, 16 bytes)

/// One accelerometer sample (ADXL345, 100 Hz, raw, gravity included).
public struct BlueLineMEMSSample: Equatable, Sendable {
    static let byteCount = 16
    /// ADXL345 full resolution: 3.9 mg per count.
    public static let gPerCount = 0.0039

    public let session: UInt16
    public let memsIndex: UInt32
    /// EEG sample index when this sample was read; nil while the signal is stopped.
    /// Approximate alignment, not a hardware timestamp.
    public let signalIndex: UInt32?
    public let x: Int16
    public let y: Int16
    public let z: Int16

    /// Acceleration in g (about 1 g in total at rest).
    public var xG: Double { Double(x) * Self.gPerCount }
    public var yG: Double { Double(y) * Self.gPerCount }
    public var zG: Double { Double(z) * Self.gPerCount }

    public init?(_ data: Data) {
        guard data.count >= Self.byteCount else { return nil }
        let r = ByteReader(data)
        session = r.u16(0)
        memsIndex = r.u32(2)
        let index = r.u32(6)
        signalIndex = index == 0xFFFF_FFFF ? nil : index
        x = Int16(bitPattern: r.u16(10))
        y = Int16(bitPattern: r.u16(12))
        z = Int16(bitPattern: r.u16(14))
    }
}

// MARK: - Status (read + notify, 20 bytes)

/// Device state and per-session loss counters.
public struct BlueLineStatus: Equatable, Sendable {
    public struct Flags: OptionSet, Equatable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let memsOn    = Flags(rawValue: 1 << 0)
        public static let txBlocked = Flags(rawValue: 1 << 1)
        public static let adsFault  = Flags(rawValue: 1 << 2)
        public static let adxlFault = Flags(rawValue: 1 << 3)
    }

    static let byteCount = 20

    public let isStreaming: Bool
    public let flags: Flags
    public let batteryPercent: Int
    public let gain: Int
    public let mtu: Int
    public let session: UInt16
    /// Samples dropped because the BLE queue was full, this session.
    public let signalSamplesDropped: UInt32
    /// ADC frames lost before processing, this session.
    public let adcFramesLost: UInt32
    public let memsSamplesDropped: UInt32

    public init?(_ data: Data) {
        guard data.count >= Self.byteCount else { return nil }
        let r = ByteReader(data)
        isStreaming = r.u8(0) == 1
        flags = Flags(rawValue: r.u8(1))
        batteryPercent = Int(r.u8(2))
        gain = Int(r.u8(3))
        mtu = Int(r.u16(4))
        session = r.u16(6)
        signalSamplesDropped = r.u32(8)
        adcFramesLost = r.u32(12)
        memsSamplesDropped = r.u32(16)
    }
}

// MARK: - Control (write request + notify)

/// Control opcodes.
public enum BlueLineCommand: UInt8, Sendable {
    case startSignal = 0x01
    case stopSignal  = 0x02
    case startMEMS   = 0x03
    case stopMEMS    = 0x04
    case startResist = 0x05
    case stopResist  = 0x06
    case setGain     = 0x10
    case identify    = 0x20

    /// Answer to a request written while the previous one was still running.
    static let busyOpcode: UInt8 = 0xFF
    /// Gains accepted by SET_GAIN.
    public static let supportedGains: [Int] = [1, 2, 4, 6, 8, 12, 24]

    func request(_ params: [UInt8] = []) -> Data { Data([rawValue] + params) }
}

/// Control result codes.
public enum BlueLineResult: UInt8, Sendable {
    case ok            = 0
    case notSupported  = 1
    case invalidParam  = 2
    case invalidState  = 3
    case busy          = 4
    case hardwareFault = 5
}

struct BlueLineControlResponse {
    let opcode: UInt8
    let result: BlueLineResult?
    let rawResult: UInt8
    let payload: [UInt8]

    init?(_ data: Data) {
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data)
        opcode = bytes[0]
        rawResult = bytes[1]
        result = BlueLineResult(rawValue: bytes[1])
        payload = Array(bytes.dropFirst(2))
    }

    var isOK: Bool { result == .ok }

    /// START_SIGNAL: session u16. SET_GAIN: gain u8, session u16.
    var session: UInt16? {
        let offset: Int
        switch BlueLineCommand(rawValue: opcode) {
        case .startSignal: offset = 0
        case .setGain:     offset = 1
        default:           return nil
        }
        guard payload.count >= offset + 2 else { return nil }
        return UInt16(payload[offset]) | UInt16(payload[offset + 1]) << 8
    }
}
