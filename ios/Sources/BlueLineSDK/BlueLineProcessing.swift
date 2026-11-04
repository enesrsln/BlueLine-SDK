//
//  BlueLineProcessing.swift
//  BlueLineSDK
//
//  EEG signal processing: filters, spectrum and band powers.
//
//  The same algorithms as the other BlueLine SDKs, checked by
//  testvectors/blueline_processing_v1.json. Pure Swift (no Accelerate), no
//  CoreBluetooth. The classes keep state and are not thread-safe: use each from
//  one queue, for example the queue `onSignal` is called on.
//

import Foundation

/// An EEG frequency band in Hz, `low <= f < high`.
public struct EEGBand: Equatable, Sendable {
    public let name: String
    public let low: Double
    public let high: Double

    public init(_ name: String, low: Double, high: Double) {
        precondition(low < high, "EEGBand: low must be below high")
        self.name = name
        self.low = low
        self.high = high
    }

    public var width: Double { high - low }

    /// Default EEG bands: delta 1–4, theta 4–8, alpha 8–13, beta 13–30, gamma 30–45 Hz.
    public static let defaults: [EEGBand] = [
        EEGBand("delta", low: 1, high: 4),
        EEGBand("theta", low: 4, high: 8),
        EEGBand("alpha", low: 8, high: 13),
        EEGBand("beta", low: 13, high: 30),
        EEGBand("gamma", low: 30, high: 45),
    ]
}

// MARK: - Filters

/// One second-order IIR section (direct form II transposed), `a0 == 1`.
///
/// Starts in the steady state of its first input sample, so a large electrode
/// offset does not ring through a high-pass filter.
public final class Biquad {
    public let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var s1 = 0.0
    private var s2 = 0.0
    private var started = false

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    public var dcGain: Double { (b0 + b1 + b2) / (1 + a1 + a2) }

    /// `[b0, b1, b2, a1, a2]`.
    public var coefficients: [Double] { [b0, b1, b2, a1, a2] }

    /// Forgets the past; the next sample sets the starting state again.
    public func reset() {
        s1 = 0; s2 = 0; started = false
    }

    public func filter(_ x: Double) -> Double {
        if !started {
            let g = dcGain
            s2 = (b2 - a2 * g) * x
            s1 = (b1 - a1 * g) * x + s2
            started = true
        }
        let y = b0 * x + s1
        s1 = b1 * x - a1 * y + s2
        s2 = b2 * x - a2 * y
        return y
    }

    func response(frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), n1 = -sin(w), c2 = cos(2 * w), n2 = -sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = b1 * n1 + b2 * n2
        let dr = 1 + a1 * c1 + a2 * c2, di = a1 * n1 + a2 * n2
        return (nr * nr + ni * ni).squareRoot() / (dr * dr + di * di).squareRoot()
    }

    func copy() -> Biquad { Biquad(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2) }
}

/// A cascade of biquads for one channel. Build one with the static functions.
public final class BlueLineFilter: CustomStringConvertible {
    public let sections: [Biquad]
    public let name: String

    public init(sections: [Biquad], name: String = "custom") {
        self.sections = sections
        self.name = name
    }

    public var description: String { "BlueLineFilter(\(name), \(sections.count) sections)" }

    /// Butterworth low-pass; `order` 2, 4, 6 or 8 (-3 dB at `cutoff`).
    public static func lowpass(sampleRate: Double, cutoff: Double, order: Int = 4) throws -> BlueLineFilter {
        let w0 = try omega(sampleRate, cutoff)
        return BlueLineFilter(sections: try butterworthQs(order).map { section(w0, $0, low: true) },
                              name: "lowpass \(fmt(cutoff)) Hz")
    }

    /// Butterworth high-pass; removes the electrode offset and slow drift.
    public static func highpass(sampleRate: Double, cutoff: Double, order: Int = 4) throws -> BlueLineFilter {
        let w0 = try omega(sampleRate, cutoff)
        return BlueLineFilter(sections: try butterworthQs(order).map { section(w0, $0, low: false) },
                              name: "highpass \(fmt(cutoff)) Hz")
    }

    /// Narrow band-stop for mains: 50 Hz (Europe, Turkey) or 60 Hz. -3 dB width = frequency / quality.
    public static func notch(sampleRate: Double, frequency: Double = 50, quality: Double = 30) throws -> BlueLineFilter {
        let w0 = try omega(sampleRate, frequency)
        guard quality > 0 else { throw BlueLineError.invalidParameter("quality must be positive") }
        let g = 1 / (1 + tan(w0 / quality / 2))
        let c = cos(w0)
        return BlueLineFilter(sections: [Biquad(b0: g, b1: -2 * g * c, b2: g, a1: -2 * g * c, a2: 2 * g - 1)],
                              name: "notch \(fmt(frequency)) Hz")
    }

    /// High-pass at `low` followed by low-pass at `high`.
    public static func bandpass(sampleRate: Double, low: Double, high: Double, order: Int = 4) throws -> BlueLineFilter {
        guard low < high else { throw BlueLineError.invalidParameter("low must be below high") }
        let hp = try highpass(sampleRate: sampleRate, cutoff: low, order: order)
        let lp = try lowpass(sampleRate: sampleRate, cutoff: high, order: order)
        return BlueLineFilter(sections: hp.sections + lp.sections, name: "bandpass \(fmt(low))-\(fmt(high)) Hz")
    }

    public func reset() { sections.forEach { $0.reset() } }

    public func filter(_ x: Double) -> Double {
        var v = x
        for s in sections { v = s.filter(v) }
        return v
    }

    public func filter(_ values: [Double]) -> [Double] { values.map { filter($0) } }

    /// Magnitude response (1.0 = passes unchanged) at `frequency`.
    public func response(frequency: Double, sampleRate: Double) -> Double {
        sections.reduce(1.0) { $0 * $1.response(frequency: frequency, sampleRate: sampleRate) }
    }

    /// Same coefficients, fresh state (for another channel).
    public func copy() -> BlueLineFilter { BlueLineFilter(sections: sections.map { $0.copy() }, name: name) }

    private static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    private static func omega(_ sampleRate: Double, _ frequency: Double) throws -> Double {
        guard frequency > 0, frequency < sampleRate / 2 else {
            throw BlueLineError.invalidParameter(
                "frequency must be between 0 and \(sampleRate / 2) Hz (Nyquist), got \(frequency)")
        }
        return 2 * Double.pi * frequency / sampleRate
    }

    private static func butterworthQs(_ order: Int) throws -> [Double] {
        guard order >= 2, order % 2 == 0 else { throw BlueLineError.invalidParameter("order must be an even number >= 2") }
        return (0..<(order / 2)).map { k in 1 / (2 * cos(Double.pi * Double(2 * k + 1) / Double(2 * order))) }
    }

    private static func section(_ w0: Double, _ q: Double, low: Bool) -> Biquad {
        let c = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        let b = (low ? 1 - c : 1 + c) / 2 / a0
        return Biquad(b0: b, b1: low ? 2 * b : -2 * b, b2: b, a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }
}

/// Filters applied one after another to a single channel.
public final class BlueLineFilterList {
    public private(set) var filters: [BlueLineFilter]

    public init(_ filters: [BlueLineFilter] = []) { self.filters = filters }

    public func add(_ filter: BlueLineFilter) { filters.append(filter) }

    public func reset() { filters.forEach { $0.reset() } }

    public func filter(_ x: Double) -> Double {
        var v = x
        for f in filters { v = f.filter(v) }
        return v
    }

    public func filter(_ values: [Double]) -> [Double] { values.map { filter($0) } }

    public func response(frequency: Double, sampleRate: Double) -> Double {
        filters.reduce(1.0) { $0 * $1.response(frequency: frequency, sampleRate: sampleRate) }
    }

    public func copy() -> BlueLineFilterList { BlueLineFilterList(filters.map { $0.copy() }) }
}

/// Detects a new session or lost samples between packets.
private struct Continuity {
    private var session: UInt16?

    mutating func broken(_ packet: BlueLineSignalPacket) -> Bool {
        let broken = packet.gapBefore || packet.session != session
        session = packet.session
        return broken
    }
}

/// The same filter chain on every channel of a stream.
///
/// Default: 0.5–40 Hz band-pass (4th-order Butterworth) and a 50 Hz notch. Pass
/// `notch: 60` in the Americas, `nil` to leave a stage out, or your own
/// `filters` to replace the defaults.
public final class SignalFilter {
    public let sampleRate: Double
    public let channels: [BlueLineFilterList]
    private var continuity = Continuity()

    public init(channelCount: Int, sampleRate: Double = 250, highpass: Double? = 0.5, lowpass: Double? = 40,
                notch: Double? = 50, order: Int = 4, filters: [BlueLineFilter]? = nil) throws {
        self.sampleRate = sampleRate
        var chain: [BlueLineFilter]
        if let filters = filters {
            chain = filters.map { $0.copy() }
        } else {
            chain = []
            if let highpass { chain.append(try BlueLineFilter.highpass(sampleRate: sampleRate, cutoff: highpass, order: order)) }
            if let lowpass { chain.append(try BlueLineFilter.lowpass(sampleRate: sampleRate, cutoff: lowpass, order: order)) }
            if let notch { chain.append(try BlueLineFilter.notch(sampleRate: sampleRate, frequency: notch)) }
        }
        let template = BlueLineFilterList(chain)
        channels = (0..<channelCount).map { _ in template.copy() }
    }

    public func reset() { channels.forEach { $0.reset() } }

    /// Filters `[sample][channel]` values that continue the previous call.
    public func filter(rows: [[Double]]) -> [[Double]] {
        rows.map { row in row.enumerated().map { channels[$0.offset].filter($0.element) } }
    }

    /// Filtered microvolts of `packet` as `[sample][channel]`. Resets first when the
    /// packet starts a new session or follows lost samples; allow 1–2 s to settle.
    public func process(_ packet: BlueLineSignalPacket) -> [[Double]] {
        if continuity.broken(packet) { reset() }
        return filter(rows: packet.microvolts)
    }
}

// MARK: - Spectrum

/// One-sided power spectral density: `psd` in µV²/Hz at `frequencies` (Hz).
public struct PowerSpectrum: Sendable {
    public let frequencies: [Double]
    public let psd: [Double]
}

public enum BlueLineSpectrum {
    /// Periodic Hann window.
    public static func hannWindow(_ n: Int) -> [Double] {
        (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n)) }
    }

    /// PSD of one channel: mean removed, Hann window, zero-padded to `nfft`
    /// (default: next power of two), up to `maxFrequency` if given.
    /// Matches `scipy.signal.periodogram(x, fs, window="hann", nfft=nfft)`.
    public static func powerSpectrum(_ values: [Double], sampleRate: Double, nfft: Int? = nil,
                                     maxFrequency: Double? = nil) throws -> PowerSpectrum {
        let n = values.count
        guard n >= 2 else { throw BlueLineError.invalidParameter("need at least 2 samples") }
        var size = 1
        while size < n { size <<= 1 }
        if let nfft { size = nfft }
        guard size >= n, size & (size - 1) == 0 else {
            throw BlueLineError.invalidParameter("nfft must be a power of two and at least the number of values")
        }
        let mean = values.reduce(0, +) / Double(n)
        let window = hannWindow(n)
        let scale = 1 / (sampleRate * window.reduce(0) { $0 + $1 * $1 })
        var re = [Double](repeating: 0, count: size)
        var im = [Double](repeating: 0, count: size)
        for i in 0..<n { re[i] = (values[i] - mean) * window[i] }
        fft(&re, &im)
        let df = sampleRate / Double(size)
        var bins = size / 2 + 1
        if let maxFrequency { bins = (0..<bins).filter { Double($0) * df <= maxFrequency }.count }
        let psd = (0..<bins).map { k -> Double in
            (re[k] * re[k] + im[k] * im[k]) * scale * (k == 0 || k == size / 2 ? 1 : 2)
        }
        return PowerSpectrum(frequencies: (0..<bins).map { Double($0) * df }, psd: psd)
    }

    /// Power in each band (µV² for a µV spectrum): PSD summed over `low <= f < high` times the bin width.
    public static func bandPowers(_ spectrum: PowerSpectrum, bands: [EEGBand] = EEGBand.defaults) -> [String: Double] {
        let f = spectrum.frequencies
        guard f.count >= 2 else { return [:] }
        let df = f[1] - f[0]
        var result: [String: Double] = [:]
        for band in bands {
            var sum = 0.0
            for k in f.indices where f[k] >= band.low && f[k] < band.high { sum += spectrum.psd[k] }
            result[band.name] = sum * df
        }
        return result
    }

    /// Each band's share of the total, summing to 1. With `normalizeByBandwidth`
    /// each band is first divided by its width, so wide bands do not dominate.
    public static func relativePowers(_ powers: [String: Double], bands: [EEGBand] = EEGBand.defaults,
                                      normalizeByBandwidth: Bool = false) -> [String: Double] {
        var p: [String: Double] = [:]
        for band in bands {
            guard let v = powers[band.name] else { continue }
            p[band.name] = normalizeByBandwidth ? v / band.width : v
        }
        // Sum in band order, as the other SDKs do.
        let total = bands.compactMap { p[$0.name] }.reduce(0, +)
        return p.mapValues { total > 0 ? $0 / total : 0 }
    }

    /// In-place radix-2 FFT.
    static func fft(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        var j = 0
        for i in 1..<max(n, 1) {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j |= bit
            if i < j {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }
        var size = 2
        while size <= n {
            let half = size / 2
            let step = -2 * Double.pi / Double(size)
            for k in 0..<half {
                let wr = cos(step * Double(k))
                let wi = sin(step * Double(k))
                var start = k
                while start < n {
                    let a = start + half
                    let tr = wr * re[a] - wi * im[a]
                    let ti = wr * im[a] + wi * re[a]
                    re[a] = re[start] - tr
                    im[a] = im[start] - ti
                    re[start] += tr
                    im[start] += ti
                    start += size
                }
            }
            size *= 2
        }
    }
}

public struct ChannelSpectrum: Sendable {
    /// PSD in µV²/Hz at `SpectrumFrame.frequencies`.
    public let psd: [Double]
    /// Absolute band power in µV², by band name.
    public let powers: [String: Double]
    /// Share of each band in the total of all bands (sums to 1).
    public let relative: [String: Double]
}

/// Spectrum of the last window of every channel.
public struct SpectrumFrame: Sendable {
    public let session: UInt16
    /// Index of the sample after the window.
    public let endIndex: UInt32
    public let frequencies: [Double]
    public let channels: [ChannelSpectrum]

    /// Seconds since the session started at the end of the window.
    public func endTime(sampleRate: Double) -> Double { Double(endIndex) / sampleRate }
}

/// Sliding-window spectrum and band powers of every channel.
///
/// Keeps the last `window` seconds (default 4 s = 1000 samples at 250 Hz) and
/// computes a `SpectrumFrame` `updateRate` times per second once the window is
/// full. After a new session or lost samples the window fills again, so a frame
/// never spans a gap. Feed it raw microvolts; the mean of each window is removed.
public final class SpectrumAnalyzer {
    public let channelCount: Int
    public let sampleRate: Double
    public let windowSamples: Int
    public let stepSamples: Int
    public let maxFrequency: Double
    public let bands: [EEGBand]
    public let normalizeByBandwidth: Bool
    private var ring: [[Double]]
    private var count = 0
    private var head = 0
    private var untilNext: Int
    private var nextIndex: UInt32 = 0
    private var continuity = Continuity()

    public init(channelCount: Int, sampleRate: Double = 250, window: Double = 4, updateRate: Double = 5,
                maxFrequency: Double = 50, bands: [EEGBand] = EEGBand.defaults,
                normalizeByBandwidth: Bool = false) throws {
        let windowSamples = Int((window * sampleRate).rounded())
        guard windowSamples >= 16 else { throw BlueLineError.invalidParameter("window too short") }
        guard updateRate > 0 else { throw BlueLineError.invalidParameter("updateRate must be positive") }
        self.windowSamples = windowSamples
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        stepSamples = max(1, Int((sampleRate / updateRate).rounded()))
        self.maxFrequency = maxFrequency
        self.bands = bands
        self.normalizeByBandwidth = normalizeByBandwidth
        ring = Array(repeating: [Double](repeating: 0, count: windowSamples), count: channelCount)
        untilNext = windowSamples
    }

    /// How full the window is, 0.0–1.0.
    public var fill: Double { Double(count) / Double(windowSamples) }

    public func reset() {
        count = 0; head = 0; untilNext = windowSamples; nextIndex = 0
    }

    /// Adds a packet; returns the frames it completed (often none, sometimes one).
    public func process(_ packet: BlueLineSignalPacket) -> [SpectrumFrame] {
        if continuity.broken(packet) { reset() }
        return add(rows: packet.microvolts, session: packet.session, firstIndex: packet.firstIndex)
    }

    /// Adds `[sample][channel]` values that continue the previous call.
    public func add(rows: [[Double]], session: UInt16 = 0, firstIndex: UInt32? = nil) -> [SpectrumFrame] {
        var index = firstIndex ?? nextIndex
        var frames: [SpectrumFrame] = []
        for row in rows {
            for c in 0..<channelCount { ring[c][head] = row[c] }
            head = (head + 1) % windowSamples
            if count < windowSamples { count += 1 }
            index &+= 1
            untilNext -= 1
            if untilNext <= 0 {
                untilNext = stepSamples
                frames.append(compute(session: session, endIndex: index))
            }
        }
        nextIndex = index
        return frames
    }

    private func compute(session: UInt16, endIndex: UInt32) -> SpectrumFrame {
        var frequencies: [Double] = []
        let channels = ring.map { buf -> ChannelSpectrum in
            // oldest sample first
            let ordered = (0..<windowSamples).map { buf[(head + $0) % windowSamples] }
            // Cannot throw: the window has at least 16 samples and nfft is derived from it.
            let spectrum = try! BlueLineSpectrum.powerSpectrum(ordered, sampleRate: sampleRate,
                                                               maxFrequency: maxFrequency)
            frequencies = spectrum.frequencies
            let powers = BlueLineSpectrum.bandPowers(spectrum, bands: bands)
            return ChannelSpectrum(psd: spectrum.psd, powers: powers,
                                   relative: BlueLineSpectrum.relativePowers(powers, bands: bands,
                                                                             normalizeByBandwidth: normalizeByBandwidth))
        }
        return SpectrumFrame(session: session, endIndex: endIndex, frequencies: frequencies, channels: channels)
    }
}
