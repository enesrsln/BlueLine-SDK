import XCTest
@testable import BlueLineSDK

/// Runs testvectors/blueline_processing_v1.json and checks the processing classes.
final class BlueLineProcessingTests: XCTestCase {
    private let fs = 250.0

    private static let vectors: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // BlueLineSDKTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // ios
            .deletingLastPathComponent()      // BlueLineSDK
            .appendingPathComponent("testvectors/blueline_processing_v1.json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    private func doubles(_ any: Any?) -> [Double] { (any as! [NSNumber]).map { $0.doubleValue } }

    private func assertClose(_ actual: [Double], _ expected: [Double], _ name: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, "\(name): count", file: file, line: line)
        let tol = 1e-9 * max(1e-12, expected.map(abs).max() ?? 0)
        for (i, (a, e)) in zip(actual, expected).enumerated() where abs(a - e) > tol {
            XCTFail("\(name)[\(i)]: expected \(e), got \(a)", file: file, line: line)
            return
        }
    }

    private var bands: [EEGBand] {
        let b = Self.vectors["bands"] as! [String: [NSNumber]]
        // JSON objects are unordered: use the default order, check the limits.
        return EEGBand.defaults.map { band in
            let limits = b[band.name]!
            return EEGBand(band.name, low: limits[0].doubleValue, high: limits[1].doubleValue)
        }
    }

    /// Values of a JSON object in band order.
    private func ordered(_ any: Any?, _ bands: [EEGBand]) -> [Double] {
        let o = any as! [String: NSNumber]
        return bands.map { o[$0.name]!.doubleValue }
    }

    func testFilterVectors() throws {
        for case let c as [String: Any] in Self.vectors["filters"] as! [Any] {
            let name = c["name"] as! String
            let sr = (c["sampleRate"] as! NSNumber).doubleValue
            let freq = (c["frequency"] as! NSNumber).doubleValue
            let f: BlueLineFilter
            switch c["type"] as! String {
            case "lowpass": f = try .lowpass(sampleRate: sr, cutoff: freq, order: (c["order"] as! NSNumber).intValue)
            case "highpass": f = try .highpass(sampleRate: sr, cutoff: freq, order: (c["order"] as! NSNumber).intValue)
            case "notch": f = try .notch(sampleRate: sr, frequency: freq, quality: (c["quality"] as! NSNumber).doubleValue)
            default: XCTFail("unknown filter type"); continue
            }
            let sections = (c["sections"] as! [Any]).flatMap { doubles($0) }
            assertClose(f.sections.flatMap { $0.coefficients }, sections, "\(name) coefficients")
            assertClose(f.filter(doubles(c["input"])), doubles(c["output"]), name)
        }
    }

    func testDefaultSignalFilterVector() throws {
        let c = Self.vectors["signalFilterDefault"] as! [String: Any]
        let filter = try SignalFilter(channelCount: 1, sampleRate: (c["sampleRate"] as! NSNumber).doubleValue)
        let out = filter.filter(rows: doubles(c["input"]).map { [$0] }).map { $0[0] }
        assertClose(out, doubles(c["output"]), "default chain")
    }

    func testSpectrumVectors() throws {
        let bands = self.bands
        for case let c as [String: Any] in Self.vectors["spectrum"] as! [Any] {
            let name = c["name"] as! String
            let s = try BlueLineSpectrum.powerSpectrum(
                doubles(c["input"]), sampleRate: (c["sampleRate"] as! NSNumber).doubleValue,
                nfft: (c["nfft"] as! NSNumber).intValue, maxFrequency: (c["maxFrequency"] as! NSNumber).doubleValue)
            assertClose(s.frequencies, doubles(c["frequencies"]), "\(name) frequencies")
            assertClose(s.psd, doubles(c["psd"]), "\(name) psd")
            let powers = BlueLineSpectrum.bandPowers(s, bands: bands)
            assertClose(bands.map { powers[$0.name]! }, ordered(c["bandPowers"], bands), "\(name) powers")
            if c["relative"] != nil {
                let rel = BlueLineSpectrum.relativePowers(powers, bands: bands)
                assertClose(bands.map { rel[$0.name]! }, ordered(c["relative"], bands), "\(name) relative")
                let norm = BlueLineSpectrum.relativePowers(powers, bands: bands, normalizeByBandwidth: true)
                assertClose(bands.map { norm[$0.name]! }, ordered(c["relativeNormalizedByBandwidth"], bands),
                            "\(name) relative normalized")
            }
        }
    }

    func testResponses() throws {
        let notch = try BlueLineFilter.notch(sampleRate: fs, frequency: 50)
        XCTAssertLessThan(notch.response(frequency: 50, sampleRate: fs), 1e-6)
        XCTAssertEqual(notch.response(frequency: 10, sampleRate: fs), 1, accuracy: 0.01)
        for order in [2, 4, 6, 8] {
            XCTAssertEqual(try BlueLineFilter.lowpass(sampleRate: fs, cutoff: 40, order: order)
                .response(frequency: 40, sampleRate: fs), 0.5.squareRoot(), accuracy: 1e-9)
            XCTAssertEqual(try BlueLineFilter.highpass(sampleRate: fs, cutoff: 0.5, order: order)
                .response(frequency: 0.5, sampleRate: fs), 0.5.squareRoot(), accuracy: 1e-9)
        }
        let offset = try BlueLineFilter.highpass(sampleRate: fs, cutoff: 0.5).filter([Double](repeating: 10000, count: 500))
        XCTAssertLessThan(offset.map(abs).max()!, 1e-6)
    }

    func testInvalidParameters() {
        XCTAssertThrowsError(try BlueLineFilter.lowpass(sampleRate: fs, cutoff: 125))
        XCTAssertThrowsError(try BlueLineFilter.highpass(sampleRate: fs, cutoff: 1, order: 3))
        XCTAssertThrowsError(try BlueLineFilter.bandpass(sampleRate: fs, low: 40, high: 1))
        XCTAssertThrowsError(try BlueLineFilter.notch(sampleRate: fs, frequency: 50, quality: 0))
        XCTAssertThrowsError(try SpectrumAnalyzer(channelCount: 1, window: 0.01))
    }

    // MARK: - Packets

    private func packet(session: UInt16, first: UInt32, rows: [[Int32]], gap: Bool = false) -> BlueLineSignalPacket {
        var bytes: [UInt8] = [gap ? 1 : 0, UInt8(rows.count), UInt8(session & 0xFF), UInt8(session >> 8)]
        bytes += (0..<4).map { UInt8(truncatingIfNeeded: first >> (8 * $0)) }
        for row in rows {
            for v in row {
                let raw = UInt32(bitPattern: v)
                bytes += [UInt8(truncatingIfNeeded: raw >> 16), UInt8(truncatingIfNeeded: raw >> 8), UInt8(truncatingIfNeeded: raw)]
            }
        }
        var p = BlueLineSignalPacket(Data(bytes), channelCount: rows[0].count)!
        p.microvoltsPerCount = 1    // counts are microvolts
        return p
    }

    func testSignalFilterResetsOnGapAndSession() throws {
        let filter = try SignalFilter(channelCount: 1, sampleRate: fs)
        _ = filter.process(packet(session: 1, first: 0, rows: Array(repeating: [0], count: 5)))
        XCTAssertGreaterThan(abs(filter.process(packet(session: 1, first: 5, rows: [[5000]]))[0][0]), 1e-3)
        XCTAssertEqual(filter.process(packet(session: 1, first: 20, rows: [[5000]], gap: true))[0][0], 0, accuracy: 1e-6)
        XCTAssertEqual(filter.process(packet(session: 2, first: 0, rows: [[-300]]))[0][0], 0, accuracy: 1e-6)
    }

    private func feed(_ analyzer: SpectrumAnalyzer, session: UInt16, first: UInt32, count: Int,
                      gap: Bool = false) -> [SpectrumFrame] {
        var frames: [SpectrumFrame] = []
        for i in stride(from: 0, to: count, by: 10) {
            let rows = (i..<min(count, i + 10)).map { k -> [Int32] in
                let v = Int32(3000 * sin(2 * Double.pi * 10 * Double(Int(first) + k) / fs))
                return [v, -v]
            }
            frames += analyzer.process(packet(session: session, first: first + UInt32(i), rows: rows, gap: gap && i == 0))
        }
        return frames
    }

    func testAnalyzerFramesAndRestarts() throws {
        let analyzer = try SpectrumAnalyzer(channelCount: 2, sampleRate: fs)
        let frames = feed(analyzer, session: 1, first: 0, count: 1500)
        XCTAssertEqual(frames.map { $0.endIndex }, Array(stride(from: UInt32(1000), through: 1500, by: 50)))
        let last = try XCTUnwrap(frames.last)
        XCTAssertEqual(last.endTime(sampleRate: fs), 6, accuracy: 1e-12)
        XCTAssertGreaterThan(last.channels[0].relative["alpha"]!, 0.99)
        XCTAssertEqual(last.channels[0].powers["alpha"]!, 3000 * 3000 / 2, accuracy: 3000 * 3000 / 2 * 0.01)
        XCTAssertEqual(last.channels[1].relative.values.reduce(0, +), 1, accuracy: 1e-12)

        let restart = try SpectrumAnalyzer(channelCount: 2, sampleRate: fs)
        _ = feed(restart, session: 1, first: 0, count: 900)
        XCTAssertEqual(restart.fill, 0.9, accuracy: 1e-12)
        XCTAssertTrue(feed(restart, session: 1, first: 1000, count: 900, gap: true).isEmpty)
        XCTAssertTrue(feed(restart, session: 2, first: 0, count: 990).isEmpty)
        XCTAssertEqual(feed(restart, session: 2, first: 990, count: 10).count, 1)
    }
}
