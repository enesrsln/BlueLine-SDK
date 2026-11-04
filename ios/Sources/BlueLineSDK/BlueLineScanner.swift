//
//  BlueLineScanner.swift
//  BlueLineSDK
//
//  Finds BlueLine devices and opens connections. Owns the CBCentralManager;
//  keep one scanner alive for as long as you use its devices.
//

import Foundation
@preconcurrency import CoreBluetooth

/// A BlueLine device seen while scanning.
public struct BlueLineDiscovery {
    public let peripheral: CBPeripheral
    public var identifier: UUID { peripheral.identifier }
    public let name: String
    public let rssi: Int
    /// Model and chip id from the scan response, when present.
    public let advertisement: BlueLineAdvertisement?
}

/// All state lives on `queue`; public methods may be called from any thread.
public final class BlueLineScanner: NSObject, @unchecked Sendable {
    /// Every callback and async result is delivered on this queue.
    public let queue: DispatchQueue
    public private(set) var bluetoothState: CBManagerState = .unknown
    public private(set) var isScanning = false

    public var onBluetoothStateChange: ((CBManagerState) -> Void)?
    /// Called once per device per scan (or on every advertisement with `allowDuplicates`).
    public var onDeviceFound: ((BlueLineDiscovery) -> Void)?

    private var central: CBCentralManager!
    private var devices: [UUID: BlueLineDevice] = [:]

    /// - Parameter queue: queue for Bluetooth work and all callbacks. Use `.main`
    ///   (the default) to update UI directly from callbacks.
    public init(queue: DispatchQueue = .main) {
        self.queue = queue
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    /// Scans for the BlueLine service. Bluetooth must be powered on.
    public func startScan(allowDuplicates: Bool = false) throws {
        guard bluetoothState == .poweredOn else { throw BlueLineError.bluetoothUnavailable(bluetoothState) }
        isScanning = true
        central.scanForPeripherals(withServices: [BlueLineV1.service],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates])
    }

    public func stopScan() {
        isScanning = false
        central.stopScan()
    }

    /// Connects, reads Info and the device information service, and enables
    /// notifications. The returned device is ready for `startSignal()`.
    public func connect(_ discovery: BlueLineDiscovery, timeout: TimeInterval = 15) async throws -> BlueLineDevice {
        guard bluetoothState == .poweredOn else { throw BlueLineError.bluetoothUnavailable(bluetoothState) }
        let peripheral = discovery.peripheral
        let device = BlueLineDevice(peripheral: peripheral, name: discovery.name, scanner: self)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { return continuation.resume(throwing: BlueLineError.notConnected) }
                self.devices[peripheral.identifier] = device
                device.beginConnecting(continuation: continuation, timeout: timeout) { [weak self] in
                    guard let self else { return }
                    self.devices[peripheral.identifier] = nil
                    self.central.cancelPeripheralConnection(peripheral)
                }
                self.central.connect(peripheral, options: nil)
            }
        }
    }

    /// Stops acquisition (STOP_SIGNAL) and closes the connection.
    public func disconnect(_ device: BlueLineDevice) async {
        await device.prepareForDisconnect()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                device.addDisconnectWaiter(continuation)
                self.central.cancelPeripheralConnection(device.peripheral)
            }
        }
    }
}

extension BlueLineScanner: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        if central.state != .poweredOn { isScanning = false }
        onBluetoothStateChange?(central.state)
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "BlueLine"
        let advertisement = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)
            .flatMap(BlueLineAdvertisement.init(manufacturerData:))
        onDeviceFound?(BlueLineDiscovery(peripheral: peripheral, name: name, rssi: RSSI.intValue,
                                         advertisement: advertisement))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        devices[peripheral.identifier]?.didConnect()
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        devices.removeValue(forKey: peripheral.identifier)?.didDisconnect(error: BlueLineError.connectionFailed(error))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        devices.removeValue(forKey: peripheral.identifier)?.didDisconnect(error: error)
    }
}
