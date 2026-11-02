import Foundation
import Combine

/// The heart rate an Apple Watch measured during a session it ran: each set's
/// figure, keyed by `SetEntry.id`, and each session's average and max, keyed
/// by `WorkoutDay.id` (LIFT superproject, `2026-10-28-build-plan.md` item 16).
///
/// **A side-car, not a column.** `SetEntry` and `WorkoutDay` are this app's
/// versioned models (`LiftSchemaV10`), so a column is a V11 with frozen copies
/// of every model, for a read-only number nobody edits. A JSON file in the
/// app's own Application Support costs no schema, and nothing in LiftKit
/// changes, so Coach iPhone's schema is untouched too. Not `UserDefaults`,
/// where `WatchSessionHeartRateStore` kept one pair: this grows a figure per
/// set, which is a file's worth, not a preference's.
///
/// **Only a watch writes it.** `WatchSessionImporter` records what a
/// `SESSION_FINISHED` carried when it stores the session; a phone-led session
/// gets no figure, because no phone reads heart rate from Apple Health. The
/// samples themselves stay in HealthKit, written there by the watch. Nothing
/// here goes to a coach, to LIFT web or into a CSV.
///
/// **It follows the rows.** A figure is read by its set's id, so a set the
/// lifter deletes shows none, an edit to a set's weight or reps keeps it, and
/// Undo, which puts the set back under its own id, gets it back. Entries whose
/// set or day is gone are swept (`pruned`) the next time a session is stored,
/// and a backup carries only the figures of sets it writes.
struct WorkoutHeartRates: Codable, Equatable {

    /// One watch session's pair, as `SESSION_FINISHED` sent it.
    struct Session: Codable, Equatable {
        var sessionID: UUID
        var averageBpm: Double
        var maxBpm: Double
    }

    /// `SetEntry.id` -> the set's figure, whole beats per minute.
    private(set) var sets: [String: Int] = [:]
    /// `WorkoutDay.id` -> the pair of each watch session filed under that
    /// day, in the order they arrived. A day usually holds one; a lifter who
    /// trained twice on the watch has two, and each says its own.
    private(set) var days: [String: [Session]] = [:]

    var isEmpty: Bool { sets.isEmpty && days.isEmpty }

    func maxBpm(of setID: UUID) -> Int? { sets[setID.uuidString] }

    func sessions(on dayID: UUID) -> [Session] { days[dayID.uuidString] ?? [] }

    /// A figure for a set. Anything but a positive whole number is no figure,
    /// and removes one: never a zero.
    mutating func setMaxBpm(_ bpm: Int?, for setID: UUID) {
        sets[setID.uuidString] = bpm.flatMap { $0 > 0 ? $0 : nil }
    }

    /// A session's pair on a day, replacing an earlier one from the same
    /// session (a newer revision). Nil, or a pair that is not above zero,
    /// removes it: absent means not recorded, never zero.
    mutating func setSession(_ session: Session?, sessionID: UUID, on dayID: UUID) {
        let key = dayID.uuidString
        var list = (days[key] ?? []).filter { $0.sessionID != sessionID }
        if let session, session.averageBpm > 0, session.maxBpm > 0,
           session.averageBpm.isFinite, session.maxBpm.isFinite {
            list.append(session)
        }
        days[key] = list.isEmpty ? nil : list
    }

    /// Everything whose set or day no longer exists, removed.
    func pruned(keepingSets setIDs: Set<UUID>, days dayIDs: Set<UUID>) -> WorkoutHeartRates {
        let setKeys = Set(setIDs.map(\.uuidString))
        let dayKeys = Set(dayIDs.map(\.uuidString))
        var copy = self
        copy.sets = sets.filter { setKeys.contains($0.key) }
        copy.days = days.filter { dayKeys.contains($0.key) }
        return copy
    }

    // MARK: - Reading leniently

    // Hand-written so that one bad entry costs that entry and nothing else:
    // an unreadable file would otherwise cost every figure in it.
    private enum CodingKeys: String, CodingKey { case sets, days }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawSets = (try? container.decodeIfPresent([String: Int].self, forKey: .sets)) ?? nil
        sets = (rawSets ?? [:]).filter { UUID(uuidString: $0.key) != nil && $0.value > 0 }
        let rawDays = (try? container.decodeIfPresent([String: [Session]].self, forKey: .days)) ?? nil
        days = (rawDays ?? [:]).filter { UUID(uuidString: $0.key) != nil && !$0.value.isEmpty }
    }
}

/// Where `WorkoutHeartRates` lives, and the one copy the screens read.
///
/// One file, `Application Support/WorkoutHeartRates.json` in the app's own
/// container -- not the App Group: the widget shows no heart rate. Written
/// atomically, protected until the phone is first unlocked after a restart:
/// not "complete" as progress photos are, because a watch's session arrives
/// in the background, often while the phone is locked in a bag, and a file it
/// cannot open then is a figure lost. Used from the main thread, as the store
/// and every view that reads it already are.
final class WorkoutHeartRateStore: ObservableObject {

    static let shared = WorkoutHeartRateStore()

    let url: URL
    @Published private(set) var rates: WorkoutHeartRates

    init(url: URL = WorkoutHeartRateStore.defaultURL) {
        self.url = url
        rates = Self.read(url)
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WorkoutHeartRates.json")
    }

    /// Applies `change` and writes the file, once, and only when something
    /// changed.
    func update(_ change: (inout WorkoutHeartRates) -> Void) {
        var next = rates
        change(&next)
        guard next != rates else { return }
        rates = next
        write()
    }

    private func write() {
        let fm = FileManager.default
        if rates.isEmpty {
            try? fm.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(rates) else { return }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func read(_ url: URL) -> WorkoutHeartRates {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(WorkoutHeartRates.self, from: data)
        else { return WorkoutHeartRates() }
        return decoded
    }
}
