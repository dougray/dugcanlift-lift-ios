import CoreBluetooth
import Foundation
import Observation

/// The radio side of heart rate: a `CBCentralManager` that finds Bluetooth heart
/// rate devices (service 0x180D), tells which of the ones the person added are
/// nearby, and streams one device's readings during a run. Every rule that can
/// be decided without a radio lives in `HeartRateDevices.swift` and is tested
/// there; this is the thin shell that feeds it. It is unproven on hardware
/// (there was no strap to try it against when it was written).
///
/// **It never connects to a device nobody added.** Scanning only lists; a
/// connection is made for an identifier the caller hands over, which comes from
/// the person's own list.
///
/// The `CBCentralManager` is created on first use, not with this object:
/// Settings holds one in view state, and merely opening Settings must not raise
/// the Bluetooth permission prompt.
@MainActor
@Observable
final class HeartRateCentral: NSObject {

    nonisolated(unsafe) static let service = CBUUID(string: "180D")
    nonisolated(unsafe) static let measurement = CBUUID(string: "2A37")
    nonisolated static let restoreIdentifier = "lift.heartRate"

    /// Bluetooth is switched off for LIFT in Settings. Read live, not cached.
    var isDenied: Bool { CBManager.authorization == .denied || CBManager.authorization == .restricted }
    private(set) var isPoweredOn = false

    @ObservationIgnored private var manager: CBCentralManager?

    // Scanning (the add sheet)
    @ObservationIgnored private var scanContinuation: AsyncStream<[DiscoveredDevice]>.Continuation?
    @ObservationIgnored private var discovered: [DiscoveredDevice] = []
    // Range probe (`inRange`)
    @ObservationIgnored private var probing = false
    @ObservationIgnored private var seen = Set<UUID>()

    // A run's connection
    @ObservationIgnored private var reconnect = HeartRateReconnect()
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var onReading: ((Int, Date) -> Void)?

    private func central() -> CBCentralManager {
        if let manager { return manager }
        let created = CBCentralManager(
            delegate: self, queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
                      CBCentralManagerOptionShowPowerAlertKey: false])
        manager = created
        return created
    }

    // MARK: - Scanning

    /// Heart rate devices advertising nearby, one row per device, as they appear.
    /// Ends on `stopScan()` or when the consumer stops listening.
    func scan() -> AsyncStream<[DiscoveredDevice]> {
        stopScan()
        discovered = []
        let (stream, continuation) = AsyncStream.makeStream(of: [DiscoveredDevice].self)
        scanContinuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.endScan() }
        }
        continuation.yield([])
        let manager = central()
        if manager.state == .poweredOn { startScanning(manager) }
        return stream
    }

    func stopScan() {
        scanContinuation?.finish()
        endScan()
    }

    private func endScan() {
        scanContinuation = nil
        if !probing, let manager, manager.isScanning { manager.stopScan() }
    }

    private func startScanning(_ manager: CBCentralManager) {
        guard !manager.isScanning else { return }
        manager.scanForPeripherals(withServices: [Self.service], options: nil)
    }

    // MARK: - In range

    /// The added devices that are nearby right now, in the order they were
    /// added. Looks for `within` (3 s by default; a strap advertises about once
    /// a second), plus anything the system already holds connected. Empty when
    /// Bluetooth is off or not allowed.
    func inRange(_ added: [AddedHeartRateDevice], within: Duration = .seconds(3)) async -> [AddedHeartRateDevice] {
        guard !added.isEmpty, !probing else { return [] }
        let manager = central()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: within)
        while manager.state != .poweredOn {
            // `.unknown` and `.resetting` settle in a moment; anything else will not.
            guard manager.state == .unknown || manager.state == .resetting, clock.now < deadline else { return [] }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let wanted = Set(added.map(\.id))
        probing = true
        seen = Set(manager.retrieveConnectedPeripherals(withServices: [Self.service])
            .map(\.identifier).filter(wanted.contains))
        startScanning(manager)
        try? await Task.sleep(until: deadline, clock: clock)
        probing = false
        if scanContinuation == nil { manager.stopScan() }
        let found = seen
        seen = []
        return HeartRateRange.inRange(added, seen: found)
    }

    // MARK: - A run's connection

    /// Reads one device's heart rate until `disconnect()`. A drop is answered by
    /// connecting the same device again, never another; a second `connect` for a
    /// different device while a run holds one is ignored (one source per run).
    func connect(_ id: UUID, onReading: @escaping (Int, Date) -> Void) {
        reconnect.begin(id)
        guard reconnect.target == id else { return }
        self.onReading = onReading
        _ = central()
        attemptConnection()
    }

    func disconnect() {
        reconnect.end()
        onReading = nil
        if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
    }

    private func attemptConnection() {
        guard let id = reconnect.target, let manager, manager.state == .poweredOn else { return }
        if let held = peripheral, held.identifier == id {
            if held.state == .disconnected { manager.connect(held) }
            return
        }
        guard let found = manager.retrievePeripherals(withIdentifiers: [id]).first else { return }
        peripheral = found
        found.delegate = self
        // A connect never times out: it waits until the device is back in range.
        manager.connect(found)
    }
}

extension HeartRateCentral: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            isPoweredOn = central.state == .poweredOn
            guard central.state == .poweredOn else { return }
            if scanContinuation != nil || probing { startScanning(central) }
            attemptConnection()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            // A connection that outlived the process, with no run to read it:
            // let it go. A run asks for its device again through `connect`.
            let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
            guard reconnect.target == nil else { return }
            for p in restored { central.cancelPeripheralConnection(p) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let rssi = RSSI.intValue == 127 ? nil : RSSI.intValue   // 127 is "not available"
        MainActor.assumeIsolated {
            if probing { seen.insert(id) }
            guard let scanContinuation else { return }
            discovered = HeartRateScan.merged(discovered, id: id, name: name, rssi: rssi)
            scanContinuation.yield(discovered)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        let id = peripheral.identifier
        MainActor.assumeIsolated { reconnectIfWanted(id) }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        MainActor.assumeIsolated { reconnectIfWanted(id) }
    }
}

extension HeartRateCentral {
    /// Only the run's own device, only while the run holds it.
    fileprivate func reconnectIfWanted(_ id: UUID) {
        guard let again = reconnect.onDisconnect(of: id) else { return }
        guard let manager, manager.state == .poweredOn, let held = peripheral, held.identifier == again else {
            return   // `centralManagerDidUpdateState` reconnects when Bluetooth returns
        }
        manager.connect(held)
    }
}

extension HeartRateCentral: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == Self.service {
            peripheral.discoverCharacteristics([Self.measurement], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] where characteristic.uuid == Self.measurement {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.measurement,
              let data = characteristic.value,
              let bpm = HeartRateMeasurement.bpm(from: data) else { return }
        let now = Date()
        let id = peripheral.identifier
        MainActor.assumeIsolated {
            guard reconnect.target == id else { return }
            onReading?(bpm, now)
        }
    }
}
