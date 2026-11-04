//
//  BlueLineError.swift
//  BlueLineSDK
//

import Foundation
@preconcurrency import CoreBluetooth

public enum BlueLineError: Error, LocalizedError {
    /// Bluetooth is off, unauthorized or unsupported.
    case bluetoothUnavailable(CBManagerState)
    case connectionFailed(Error?)
    /// The device does not speak BlueLine protocol v1 (firmware < 0.3.0).
    case unsupportedDevice(String)
    case timeout
    case notConnected
    /// The connection dropped while a request was pending.
    case disconnected
    case invalidParameter(String)
    /// The device answered a control request with an error result.
    case commandFailed(BlueLineCommand, BlueLineResult?)

    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let state): return "Bluetooth is not available (state \(state.rawValue))."
        case .connectionFailed(let error): return "Connection failed: \(error?.localizedDescription ?? "unknown error")."
        case .unsupportedDevice(let reason): return "Unsupported BlueLine device: \(reason)."
        case .timeout: return "The BlueLine device did not respond in time."
        case .notConnected: return "The BlueLine device is not connected."
        case .disconnected: return "The BlueLine device disconnected."
        case .invalidParameter(let reason): return "Invalid parameter: \(reason)."
        case .commandFailed(let command, let result):
            return "Command \(command) failed (\(result.map { "\($0)" } ?? "unknown result"))."
        }
    }
}
