import Foundation

// The Bluetooth heart rate path, as values: no CoreBluetooth in this file, so
// every rule here is testable without a radio. `HeartRateCentral` is the thin
// shell that feeds these.

/// A device seen while scanning, as the add sheet lists it.
struct DiscoveredDevice: Identifiable, Equatable {
    var id: UUID
    var name: String
    var rssi: Int?
}

enum HeartRateScan {
    static let unnamed = "Heart rate device"

    /// A peripheral that advertises no name still gets a row.
    static func displayName(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? unnamed : trimmed
    }

    /// Folds one advertisement into the list: one row per identifier, in the
    /// order first seen (so rows do not jump about as signals change), the
    /// newest signal, and a real name replacing the fallback but never the
    /// other way round.
    static func merged(_ list: [DiscoveredDevice], id: UUID, name: String?, rssi: Int?) -> [DiscoveredDevice] {
        var list = list
        let shown = displayName(name)
        if let at = list.firstIndex(where: { $0.id == id }) {
            if shown != unnamed { list[at].name = shown }
            list[at].rssi = rssi
        } else {
            list.append(DiscoveredDevice(id: id, name: shown, rssi: rssi))
        }
        return list
    }
}

enum HeartRateRange {
    /// The added devices that were seen, in the order they were added -- not
    /// the order they were discovered, which is whichever advertised first.
    /// Automatic takes the first of this list, so the person's own order is
    /// their preference. A device nobody added is never in it.
    static func inRange(_ added: [AddedHeartRateDevice], seen: Set<UUID>) -> [AddedHeartRateDevice] {
        var kept = Set<UUID>()
        return added.filter { seen.contains($0.id) && kept.insert($0.id).inserted }
    }
}

/// What `@AppStorage` holds. A `Codable` enum cannot be stored directly, so the
/// setting is a JSON string and the device list another; anything unreadable
/// is the default, never an error: a stored value from a build that knew more
/// kinds than this one must not leave the Settings screen broken.
enum HeartRateStorage {
    static let settingKey = "heartRateSource"
    static let devicesKey = "heartRateDevices"

    static let defaultSetting = string(for: HeartRateSetting.automatic)
    static let defaultDevices = "[]"

    static func string(for setting: HeartRateSetting) -> String {
        encoded(setting) ?? ""
    }

    static func string(for devices: [AddedHeartRateDevice]) -> String {
        encoded(devices) ?? "[]"
    }

    static func setting(from raw: String) -> HeartRateSetting {
        guard let data = raw.data(using: .utf8),
              let setting = try? JSONDecoder().decode(HeartRateSetting.self, from: data)
        else { return .automatic }
        return setting
    }

    static func devices(from raw: String) -> [AddedHeartRateDevice] {
        guard let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([AddedHeartRateDevice].self, from: data)
        else { return [] }
        return list
    }

    /// Adding a device already in the list keeps its place and refreshes its name.
    static func adding(_ device: AddedHeartRateDevice, to list: [AddedHeartRateDevice]) -> [AddedHeartRateDevice] {
        var list = list
        if let at = list.firstIndex(where: { $0.id == device.id }) {
            list[at] = device
        } else {
            list.append(device)
        }
        return list
    }

    /// A removed device cannot stay chosen: the person's choice falls back to
    /// Automatic rather than to a source they never picked.
    static func setting(_ setting: HeartRateSetting, afterRemoving id: UUID) -> HeartRateSetting {
        if case .device(let chosen) = setting, chosen == id { return .automatic }
        return setting
    }

    private static func encoded<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Reconnecting while a run records: the same device, and only that one. A run
/// has one source, so a drop is never answered by trying another device (or the
/// watch); the number simply hides while nothing arrives
/// (`LiveHeartRate.staleAfter`) and returns with the next reading.
struct HeartRateReconnect {
    /// The device this run is reading, nil when no run is recording.
    private(set) var target: UUID?

    /// Starts a run's connection. Ignored while one is already held: the source
    /// is fixed at the start.
    mutating func begin(_ id: UUID) {
        if target == nil { target = id }
    }

    mutating func end() {
        target = nil
    }

    /// The device to connect again after `id` dropped, or nil to leave it.
    func onDisconnect(of id: UUID) -> UUID? {
        guard let target, target == id else { return nil }
        return target
    }
}
