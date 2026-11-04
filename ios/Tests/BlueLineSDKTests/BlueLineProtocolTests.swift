import XCTest
@testable import BlueLineSDK

final class BlueLineProtocolTests: XCTestCase {
    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    private func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    private func be24(_ v: Int32) -> [UInt8] {
        let raw = UInt32(bitPattern: v)
        return [UInt8(truncatingIfNeeded: raw >> 16), UInt8(truncatingIfNeeded: raw >> 8), UInt8(truncatingIfNeeded: raw)]
    }

    private func infoBytes(version: UInt8 = 1, gain: UInt8 = 6, header: UInt8 = 8, features: UInt16 = 0b11011) -> [UInt8] {
        [version, 4, 0x01, 4, 0, 3, 1, 24] + le16(1000) + le16(250) + [4, gain]
            + le32(2_500_000) + le16(100) + [19, header] + le16(features) + le64(0x0123_4567_89AB_CDEF)
    }

    func testInfo() throws {
        let info = try XCTUnwrap(BlueLineInfo(Data(infoBytes())))
        XCTAssertEqual(info.protocolVersion, 1)
        XCTAssertEqual(info.model, 4)
        XCTAssertTrue(info.hasFactorySerial)
        XCTAssertEqual(info.channelCount, 4)
        XCTAssertEqual(info.firmwareVersion, "0.3.1")
        XCTAssertEqual(info.signalRateHz, 250)
        XCTAssertEqual(info.gain, 6)
        XCTAssertEqual(info.memsRateHz, 100)
        XCTAssertEqual(info.features, [.signal, .mems, .identify, .setGain])
        XCTAssertEqual(info.chipID, 0x0123_4567_89AB_CDEF)
        XCTAssertTrue(info.isSupported)
        // uV = code * 2_500_000 / (6 * 2^23)
        XCTAssertEqual(info.microvoltsPerCount, 2_500_000 / (6 * 8_388_608.0), accuracy: 1e-12)
    }

    func testInfoRejectsUnsupportedOrMalformed() {
        XCTAssertFalse(BlueLineInfo(Data(infoBytes(version: 2)))!.isSupported)
        XCTAssertFalse(BlueLineInfo(Data(infoBytes(header: 10)))!.isSupported)
        XCTAssertFalse(BlueLineInfo(Data(infoBytes(features: 0b10)))!.isSupported)
        XCTAssertNil(BlueLineInfo(Data(infoBytes(gain: 0))))
        XCTAssertNil(BlueLineInfo(Data(infoBytes().prefix(31))))
        // A Data slice with a non-zero start index decodes the same.
        XCTAssertEqual(BlueLineInfo(Data([0xAA] + infoBytes()).dropFirst()), BlueLineInfo(Data(infoBytes())))
    }

    func testSignalPacket() throws {
        let values: [[Int32]] = [[1, -1, 8_388_607, -8_388_608], [0x123456, -0x123456, 42, -42]]
        let bytes: [UInt8] = [0x01, 2] + le16(7) + le32(1_000_000) + values.flatMap { $0.flatMap(be24) }
        var packet = try XCTUnwrap(BlueLineSignalPacket(Data(bytes), channelCount: 4))
        XCTAssertTrue(packet.gapBefore)
        XCTAssertEqual(packet.session, 7)
        XCTAssertEqual(packet.firstIndex, 1_000_000)
        XCTAssertEqual(packet.samples, values)
        packet.microvoltsPerCount = 0.5
        XCTAssertEqual(packet.microvolts[1][3], -21)

        XCTAssertNil(BlueLineSignalPacket(Data(bytes.dropLast()), channelCount: 4))
        XCTAssertNil(BlueLineSignalPacket(Data(bytes + [0]), channelCount: 4))
        XCTAssertNil(BlueLineSignalPacket(Data(bytes), channelCount: 2))
        let full: [UInt8] = [0, 19] + le16(1) + le32(5) + Array(repeating: 0, count: 19 * 12)
        XCTAssertEqual(BlueLineSignalPacket(Data(full), channelCount: 4)?.samples.count, 19)
    }

    func testMEMSSample() throws {
        let bytes = le16(9) + le32(42) + le32(1234) + le16(UInt16(bitPattern: -5)) + le16(12) + le16(256)
        let sample = try XCTUnwrap(BlueLineMEMSSample(Data(bytes)))
        XCTAssertEqual(sample.session, 9)
        XCTAssertEqual(sample.memsIndex, 42)
        XCTAssertEqual(sample.signalIndex, 1234)
        XCTAssertEqual([sample.x, sample.y, sample.z], [-5, 12, 256])
        XCTAssertEqual(sample.zG, 0.9984, accuracy: 1e-9)
        let stopped = BlueLineMEMSSample(Data(le16(9) + le32(1) + le32(0xFFFF_FFFF) + le16(0) + le16(0) + le16(0)))
        XCTAssertNil(stopped?.signalIndex)
        XCTAssertNil(BlueLineMEMSSample(Data(bytes.prefix(15))))
    }

    func testStatus() throws {
        let bytes: [UInt8] = [1, 0b0110, 87, 12] + le16(247) + le16(9) + le32(3) + le32(4) + le32(5)
        let status = try XCTUnwrap(BlueLineStatus(Data(bytes)))
        XCTAssertTrue(status.isStreaming)
        XCTAssertEqual(status.flags, [.txBlocked, .adsFault])
        XCTAssertEqual(status.batteryPercent, 87)
        XCTAssertEqual(status.gain, 12)
        XCTAssertEqual(status.mtu, 247)
        XCTAssertEqual(status.session, 9)
        XCTAssertEqual([status.signalSamplesDropped, status.adcFramesLost, status.memsSamplesDropped], [3, 4, 5])
        XCTAssertNil(BlueLineStatus(Data(bytes.prefix(19))))
    }

    func testControl() throws {
        XCTAssertEqual(BlueLineCommand.startSignal.request(), Data([0x01]))
        XCTAssertEqual(BlueLineCommand.setGain.request([12]), Data([0x10, 12]))
        let start = try XCTUnwrap(BlueLineControlResponse(Data([0x01, 0x00] + le16(0x1234))))
        XCTAssertTrue(start.isOK)
        XCTAssertEqual(start.session, 0x1234)
        let gain = try XCTUnwrap(BlueLineControlResponse(Data([0x10, 0x00, 12] + le16(3))))
        XCTAssertEqual(gain.session, 3)
        XCTAssertEqual(BlueLineControlResponse(Data([0xFF, 0x04]))?.result, .busy)
        XCTAssertEqual(BlueLineControlResponse(Data([0x05, 0x01]))?.result, .notSupported)
        XCTAssertNil(BlueLineControlResponse(Data([0x01])))
    }

    func testAdvertisement() {
        let data = Data([0xFF, 0xFF, UInt8(ascii: "B"), UInt8(ascii: "L"), 4] + le32(0xDEADBEEF))
        XCTAssertEqual(BlueLineAdvertisement(manufacturerData: data), try? XCTUnwrap(BlueLineAdvertisement(manufacturerData: data)))
        XCTAssertEqual(BlueLineAdvertisement(manufacturerData: data)?.model, 4)
        XCTAssertEqual(BlueLineAdvertisement(manufacturerData: data)?.chipIDLow, 0xDEADBEEF)
        XCTAssertNil(BlueLineAdvertisement(manufacturerData: Data([0x4C, 0x00, 0x02, 0x15, 0, 0, 0, 0, 0])))
    }
}
