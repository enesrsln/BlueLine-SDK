//
//  BlueLineDevice.swift
//  BlueLineSDK
//
//  A connected BlueLine device. Commands are async; data arrives through the
//  on... callbacks on the scanner's queue.
//

import Foundation
@preconcurrency import CoreBluetooth

/// All state lives on the scanner's queue; public methods may be called from
/// any thread, callbacks arrive on that queue.
public final class BlueLineDevice: NSObject, @unchecked Sendable {
    public let peripheral: CBPeripheral
    public var identifier: UUID { peripheral.identifier }
    public let name: String

    /// Read during connection; `gain` follows `setGain(_:)`.
    public private(set) var info: BlueLineInfo!
    public private(set) var serialNumber: String?
    public private(set) var firmwareRevision: String?
    public private(set) var batteryLevel: Int?
    public private(set) var status: BlueLineStatus?
    /// Session of the running acquisition; nil while the signal is stopped.
    public private(set) var session: UInt16?
    public private(set) var isConnected = false

    /// EEG packets of the current session (~every 20 ms, 5 samples at 250 Hz).
    public var onSignal: ((BlueLineSignalPacket) -> Void)?
    /// Accelerometer samples (100 Hz) after `startMEMS()`.
    public var onMEMS: ((BlueLineMEMSSample) -> Void)?
    /// State, gain and loss counters (at most once per second for counters).
    public var onStatus: ((BlueLineStatus) -> Void)?
    public var onBatteryLevel: ((Int) -> Void)?
    /// The connection closed (error is nil after `disconnect()`).
    public var onDisconnect: ((Error?) -> Void)?

    private weak var scanner: BlueLineScanner?
    private var queue: DispatchQueue { scanner?.queue ?? .main }

    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var connectContinuation: CheckedContinuation<BlueLineDevice, Error>?
    private var connectTimeout: DispatchWorkItem?
    private var cancelConnect: (() -> Void)?
    private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextIndex: UInt32?

    private struct ControlRequest {
        let command: BlueLineCommand
        let data: Data
        let timeout: TimeInterval
        let completion: (Result<BlueLineControlResponse, Error>) -> Void
    }
    private var controlQueue: [ControlRequest] = []
    private var controlInFlight: ControlRequest?
    private var controlTimeout: DispatchWorkItem?

    init(peripheral: CBPeripheral, name: String, scanner: BlueLineScanner) {
        self.peripheral = peripheral
        self.name = name
        self.scanner = scanner
        super.init()
        peripheral.delegate = self
    }

    // MARK: - Commands

    /// Starts EEG acquisition; returns the new session. A no-op returning the
    /// current session if already streaming. Sample indices restart at 0.
    @discardableResult
    public func startSignal() async throws -> UInt16 {
        let response = try await send(.startSignal)
        guard let session = response.session else { throw BlueLineError.commandFailed(.startSignal, response.result) }
        beginSession(session)
        return session
    }

    public func stopSignal() async throws {
        _ = try await send(.stopSignal)
        session = nil
    }

    /// Starts the accelerometer stream (`onMEMS`).
    public func startMEMS() async throws {
        _ = try await send(.startMEMS)
    }

    public func stopMEMS() async throws {
        _ = try await send(.stopMEMS)
    }

    /// Sets the PGA gain (1, 2, 4, 6, 8, 12 or 24; 6 after every boot).
    /// While streaming this restarts acquisition: a new session starts and the
    /// sample index restarts at 0. Never mix samples of different sessions.
    @discardableResult
    public func setGain(_ gain: Int) async throws -> UInt16 {
        guard BlueLineCommand.supportedGains.contains(gain) else {
            throw BlueLineError.invalidParameter("gain \(gain) not in \(BlueLineCommand.supportedGains)")
        }
        let response = try await send(.setGain, params: [UInt8(gain)])
        info.gain = response.payload.first.map(Int.init) ?? gain
        guard let newSession = response.session else { throw BlueLineError.commandFailed(.setGain, response.result) }
        if session != nil { beginSession(newSession) }
        return newSession
    }

    /// Blinks the device LED green for 2 seconds.
    public func identify() async throws {
        _ = try await send(.identify)
    }

    /// Stops acquisition and closes the connection.
    public func disconnect() async {
        guard let scanner else { return }
        await scanner.disconnect(self)
    }

    private func send(_ command: BlueLineCommand, params: [UInt8] = [], timeout: TimeInterval = 3) async throws -> BlueLineControlResponse {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.enqueueControl(command, params: params, timeout: timeout) { result in
                    switch result {
                    case .success(let response) where response.isOK: continuation.resume(returning: response)
                    case .success(let response): continuation.resume(throwing: BlueLineError.commandFailed(command, response.result))
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func beginSession(_ newSession: UInt16) {
        session = newSession
        nextIndex = nil
    }

    // MARK: - Control queue (one request at a time; the firmware answers BUSY otherwise)

    private func enqueueControl(_ command: BlueLineCommand, params: [UInt8], timeout: TimeInterval,
                                completion: @escaping (Result<BlueLineControlResponse, Error>) -> Void) {
        guard isConnected else { return completion(.failure(BlueLineError.notConnected)) }
        controlQueue.append(ControlRequest(command: command, data: command.request(params),
                                           timeout: timeout, completion: completion))
        sendNextControl()
    }

    private func sendNextControl() {
        guard controlInFlight == nil, !controlQueue.isEmpty else { return }
        let request = controlQueue.removeFirst()
        guard let control = characteristics[BlueLineV1.control] else {
            request.completion(.failure(BlueLineError.notConnected))
            return sendNextControl()
        }
        controlInFlight = request
        let timeout = DispatchWorkItem { [weak self] in self?.finishControl(.failure(BlueLineError.timeout)) }
        controlTimeout = timeout
        queue.asyncAfter(deadline: .now() + request.timeout, execute: timeout)
        peripheral.writeValue(request.data, for: control, type: .withResponse)
    }

    private func finishControl(_ result: Result<BlueLineControlResponse, Error>) {
        guard let request = controlInFlight else { return }
        controlTimeout?.cancel()
        controlTimeout = nil
        controlInFlight = nil
        request.completion(result)
        sendNextControl()
    }

    // MARK: - Connection lifecycle (called by the scanner, on its queue)

    func beginConnecting(continuation: CheckedContinuation<BlueLineDevice, Error>, timeout: TimeInterval,
                         cancel: @escaping () -> Void) {
        connectContinuation = continuation
        cancelConnect = cancel
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.connectContinuation != nil else { return }
            self.cancelConnect?()
            self.finishConnecting(.failure(BlueLineError.timeout))
        }
        connectTimeout = work
        queue.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    func didConnect() {
        isConnected = true
        peripheral.discoverServices([BlueLineV1.service, BlueLineV1.batteryService, BlueLineV1.deviceInformationService])
    }

    private func finishConnecting(_ result: Result<BlueLineDevice, Error>) {
        guard let continuation = connectContinuation else { return }
        connectContinuation = nil
        connectTimeout?.cancel()
        switch result {
        case .success(let device): continuation.resume(returning: device)
        case .failure(let error):
            cancelConnect?()
            continuation.resume(throwing: error)
        }
    }

    /// Ready when Info is read and Control, Signal, Status (and MEMS) notify.
    private func finishSetupIfReady() {
        guard connectContinuation != nil, info != nil else { return }
        var required = [BlueLineV1.control, BlueLineV1.signal, BlueLineV1.status]
        if info.features.contains(.mems) { required.append(BlueLineV1.mems) }
        guard required.allSatisfy({ characteristics[$0]?.isNotifying == true }) else { return }
        finishConnecting(.success(self))
    }

    func prepareForDisconnect() async {
        guard isConnected, session != nil else { return }
        _ = try? await send(.stopSignal, timeout: 1)
        session = nil
    }

    func addDisconnectWaiter(_ continuation: CheckedContinuation<Void, Never>) {
        if isConnected { disconnectWaiters.append(continuation) } else { continuation.resume() }
    }

    func didDisconnect(error: Error?) {
        let wasConnected = isConnected
        isConnected = false
        session = nil
        controlTimeout?.cancel()
        controlTimeout = nil
        let pending = (controlInFlight.map { [$0] } ?? []) + controlQueue
        controlInFlight = nil
        controlQueue.removeAll()
        pending.forEach { $0.completion(.failure(BlueLineError.disconnected)) }
        if connectContinuation != nil {
            finishConnecting(.failure(error ?? BlueLineError.disconnected))
        } else if wasConnected {
            onDisconnect?(error)
        }
        disconnectWaiters.forEach { $0.resume() }
        disconnectWaiters.removeAll()
    }
}

// MARK: - CBPeripheralDelegate

extension BlueLineDevice: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { return finishConnecting(.failure(BlueLineError.connectionFailed(error))) }
        let services = peripheral.services ?? []
        guard let blueLine = services.first(where: { $0.uuid == BlueLineV1.service }) else {
            return finishConnecting(.failure(BlueLineError.unsupportedDevice("no BlueLine v1 service (firmware < 0.3.0?)")))
        }
        peripheral.discoverCharacteristics(
            [BlueLineV1.info, BlueLineV1.signal, BlueLineV1.mems, BlueLineV1.status, BlueLineV1.control], for: blueLine)
        for service in services {
            if service.uuid == BlueLineV1.batteryService {
                peripheral.discoverCharacteristics([BlueLineV1.batteryLevel], for: service)
            } else if service.uuid == BlueLineV1.deviceInformationService {
                peripheral.discoverCharacteristics([BlueLineV1.serialNumber, BlueLineV1.firmwareRevision], for: service)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error, service.uuid == BlueLineV1.service {
            return finishConnecting(.failure(BlueLineError.connectionFailed(error)))
        }
        for characteristic in service.characteristics ?? [] {
            characteristics[characteristic.uuid] = characteristic
            switch characteristic.uuid {
            case BlueLineV1.info, BlueLineV1.serialNumber, BlueLineV1.firmwareRevision:
                peripheral.readValue(for: characteristic)
            case BlueLineV1.status, BlueLineV1.batteryLevel:
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
            case BlueLineV1.signal, BlueLineV1.mems, BlueLineV1.control:
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error, connectContinuation != nil {
            return finishConnecting(.failure(BlueLineError.connectionFailed(error)))
        }
        finishSetupIfReady()
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == BlueLineV1.control, let error else { return }
        finishControl(.failure(BlueLineError.connectionFailed(error)))
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        switch characteristic.uuid {
        case BlueLineV1.signal:
            handleSignal(data)
        case BlueLineV1.mems:
            guard let sample = BlueLineMEMSSample(data), session == nil || sample.session == session else { return }
            onMEMS?(sample)
        case BlueLineV1.control:
            guard let response = BlueLineControlResponse(data), let request = controlInFlight,
                  response.opcode == request.command.rawValue || response.opcode == BlueLineCommand.busyOpcode else { return }
            finishControl(.success(response))
        case BlueLineV1.status:
            guard let status = BlueLineStatus(data) else { return }
            self.status = status
            onStatus?(status)
        case BlueLineV1.batteryLevel:
            guard let level = data.first.map(Int.init) else { return }
            batteryLevel = level
            onBatteryLevel?(level)
        case BlueLineV1.info:
            guard let info = BlueLineInfo(data) else {
                return finishConnecting(.failure(BlueLineError.unsupportedDevice("unreadable Info")))
            }
            guard info.isSupported else {
                return finishConnecting(.failure(BlueLineError.unsupportedDevice(
                    "protocol \(info.protocolVersion), firmware \(info.firmwareVersion)")))
            }
            self.info = info
            finishSetupIfReady()
        case BlueLineV1.serialNumber:
            serialNumber = String(decoding: data, as: UTF8.self)
        case BlueLineV1.firmwareRevision:
            firmwareRevision = String(decoding: data, as: UTF8.self)
        default:
            break
        }
    }

    private func handleSignal(_ data: Data) {
        guard let info, let session,
              var packet = BlueLineSignalPacket(data, channelCount: info.channelCount),
              packet.session == session else { return }
        if let expected = nextIndex, expected != packet.firstIndex { packet.gapBefore = true }
        nextIndex = packet.firstIndex &+ UInt32(packet.samples.count)
        packet.microvoltsPerCount = info.microvoltsPerCount
        onSignal?(packet)
    }
}
