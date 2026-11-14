import Foundation
import Observation

// Heart rate on a run: the rules, as values.
//
// Tracked and shown, never targeted: no zones, colors, thresholds or advice.
// Foundation and Observation only -- `Sources/Shared` is also compiled into the
// widget, so nothing here may import CoreBluetooth, HealthKit or SwiftData.

/// The Bluetooth Heart Rate Measurement characteristic (0x2A37).
///
/// Byte 0 is flags; bit 0 says whether the value is a UInt8 (clear) or a
/// little-endian UInt16 (set). The other flag bits (contact, energy, RR
/// intervals) come after the value and are not read.
enum HeartRateMeasurement {
    /// Beats per minute, or nil for data too short to hold one and for 0 --
    /// a strap with no skin contact reports 0, which is no reading, not a pulse.
    static func bpm(from data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }
        let value: Int
        if flags & 0x01 == 0 {
            guard bytes.count >= 2 else { return nil }
            value = Int(bytes[1])
        } else {
            guard bytes.count >= 3 else { return nil }
            value = Int(bytes[1]) | (Int(bytes[2]) << 8)
        }
        return value > 0 ? value : nil
    }
}

/// What the coach-facing setting says, stored as JSON in
/// `@AppStorage("heartRateSource")`.
enum HeartRateSetting: Codable, Equatable {
    case automatic
    case off
    case device(UUID)
    case watch
}

/// A heart rate device the person added themselves, kept as JSON in
/// `@AppStorage("heartRateDevices")`, in the order added.
struct AddedHeartRateDevice: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
}

/// Where a run's heart rate comes from.
enum LiveHeartRateSource: Equatable {
    case device(UUID, name: String)
    case watch
}

enum HeartRateSourcePicker {
    /// Automatic takes only what was added: the first added device in range, in
    /// the order added, else the watch, else nothing. It never connects to a
    /// device nobody added, whatever is advertising nearby. A chosen device that
    /// is out of range is nil, not the watch: the person picked that one.
    static func pick(
        _ setting: HeartRateSetting,
        addedInRange: [AddedHeartRateDevice],
        watchAvailable: Bool
    ) -> LiveHeartRateSource? {
        switch setting {
        case .automatic:
            if let first = addedInRange.first { return .device(first.id, name: first.name) }
            return watchAvailable ? .watch : nil
        case .device(let id):
            guard let match = addedInRange.first(where: { $0.id == id }) else { return nil }
            return .device(match.id, name: match.name)
        case .watch:
            return watchAvailable ? .watch : nil
        case .off:
            return nil
        }
    }
}

struct LiveHeartRate {
    /// No reading for this long hides the number: a stale pulse on a screen is
    /// worse than a dash.
    static let staleAfter: TimeInterval = 10

    static func shown(last: (bpm: Int, at: Date)?, now: Date) -> Int? {
        guard let last, now.timeIntervalSince(last.at) <= staleAfter else { return nil }
        return last.bpm
    }
}

/// All a run keeps of its heart rate: average, max and the source's name.
struct RunHeartRateSummary: Equatable {
    var averageBpm: Int
    var maxBpm: Int

    /// Mean rounded half up; nil when there is nothing to average.
    static func of(_ readings: [Int]) -> RunHeartRateSummary? {
        guard let maxBpm = readings.max() else { return nil }
        let sum = readings.reduce(0, +)
        let count = readings.count
        // Integer half-up: (2 * sum + count) / (2 * count).
        let average = (2 * sum + count) / (2 * count)
        return RunHeartRateSummary(averageBpm: average, maxBpm: maxBpm)
    }
}

/// One run's heart rate. The source is fixed when the session begins: a source
/// that drops is reconnected by whoever feeds the session, never swapped for
/// another mid-run, so one run is never a mix of a strap and a wrist.
@MainActor
@Observable
final class RunHeartRateSession {
    let source: LiveHeartRateSource?
    private(set) var readings: [Int] = []
    private(set) var last: (bpm: Int, at: Date)?
    private var ended = false

    init(begin source: LiveHeartRateSource?) {
        self.source = source
    }

    /// Records a reading. Ignored with no source, after `end()`, and for a
    /// value that is not a pulse.
    func receive(_ bpm: Int, at: Date) {
        guard source != nil, !ended, bpm > 0 else { return }
        readings.append(bpm)
        last = (bpm, at)
    }

    /// The number to show now, nil once the last reading is stale.
    func shown(now: Date) -> Int? {
        LiveHeartRate.shown(last: last, now: now)
    }

    func end() -> RunHeartRateSummary? {
        ended = true
        return RunHeartRateSummary.of(readings)
    }
}
