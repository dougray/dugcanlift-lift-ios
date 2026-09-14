import Foundation
import SwiftData
import LiftCore

/// Which number summarises a day under a given focus.
///
/// Android and the browser also key the exercise progression chart off the
/// focus. This app has no such chart — `estimatedOneRepMaxKg` sits unused in
/// this file — so there is deliberately no `chart` property here to go with
/// it. Add one when a chart exists to read it, not before.
enum FocusSummary { case volume, topSet, work, distance }

/// Training style.
///
/// This carried nothing but a `displayName` until 2026-09-13 — it was stored,
/// shown as a day's fallback label, and sent to a coach, but no part of the UI
/// read it, so picking one changed nothing at all. It now matches Android and
/// the browser: the same six styles, deciding which fields a set asks for,
/// what a new set starts at, which number summarises a day, and what the
/// progression chart plots.
///
/// The roster was four cases, with a `conditioning` the other two apps had
/// never heard of and no Hyrox, endurance or everything. A coach saw
/// `CONDITIONING` from an iPhone client and `HYROX` from an Android one for
/// what might be the same training. `conditioning` is kept as a decoding
/// alias rather than a case, so days already written that way land on
/// `endurance` — the closest of the six — and are re-saved as `endurance` the
/// next time the day is touched.
///
/// Every set stores every field it was given regardless of focus, so
/// switching focus never loses anything; the app just stops asking.
enum TrainingFocus: String, Codable, CaseIterable, Identifiable {
    case bodybuilding, powerlifting, crossfit, hyrox, endurance, everything

    var id: String { rawValue }

    /// Accepts what is actually on disk, including the retired
    /// `conditioning`, which predates the roster agreeing across the apps.
    static func decode(_ raw: String) -> TrainingFocus? {
        if let known = TrainingFocus(rawValue: raw) { return known }
        if raw == "conditioning" { return .endurance }
        return nil
    }

    var displayName: String {
        switch self {
        case .bodybuilding: "Bodybuilding"
        case .powerlifting: "Powerlifting"
        case .crossfit:     "CrossFit"
        case .hyrox:        "Hyrox"
        case .endurance:    "Endurance"
        case .everything:   "Everything"
        }
    }

    var showsWeight: Bool {
        switch self {
        case .endurance: false
        default: true
        }
    }

    var showsReps: Bool {
        switch self {
        case .endurance: false
        default: true
        }
    }

    var showsRPE: Bool {
        switch self {
        case .crossfit, .hyrox: false
        default: true
        }
    }

    var showsTime: Bool {
        switch self {
        case .bodybuilding, .powerlifting: false
        default: true
        }
    }

    var showsDistance: Bool {
        switch self {
        case .hyrox, .endurance, .everything: true
        default: false
        }
    }

    /// Seeds the FIRST set of an exercise only; every set after it copies the
    /// one before, which beats any constant. Nil means the focus has no
    /// opinion.
    var defaultReps: Int? {
        switch self {
        case .bodybuilding: 10
        case .powerlifting: 5
        case .everything:   8
        case .crossfit, .hyrox, .endurance: nil
        }
    }

    var summary: FocusSummary {
        switch self {
        case .bodybuilding, .everything: .volume
        case .powerlifting:              .topSet
        case .crossfit:                  .work
        case .hyrox, .endurance:         .distance
        }
    }
}

/// A day's training log.
///
/// The day is the unit of record, not a timed session — any date can be opened
/// and logged against after the fact, which is how the Android app works.
///
/// A *live session* is an optional overlay: when `liveStartedAt` is set and
/// `liveEndedAt` is not, the user is training right now, which enables rest
/// timers and Live Activities. Nothing requires it, and a day logged
/// retroactively is equally valid.
@Model
final class WorkoutDay {
    var id: UUID = UUID()

    /// One record per calendar day.
    var dayKey: String = ""
    var date: Date = Date.now

    var name: String = ""

    /// Internal rather than private so a test can write a retired raw value
    /// ("conditioning") and prove the getter still decodes it. Read and write
    /// it through `focus`; access level is not part of the persisted shape, so
    /// this is not a schema change.
    var focusRaw: String = TrainingFocus.bodybuilding.rawValue

    var focus: TrainingFocus {
        get { TrainingFocus.decode(focusRaw) ?? .bodybuilding }
        set { focusRaw = newValue.rawValue }
    }

    // Both nil for a retroactively logged day.
    var liveStartedAt: Date?
    var liveEndedAt: Date?

    var healthKitUUID: UUID?

    @Relationship(deleteRule: .cascade, inverse: \ExerciseEntry.day)
    var exercises: [ExerciseEntry] = []

    init(date: Date = .now, name: String = "", focus: TrainingFocus = .bodybuilding) {
        self.id = UUID()
        self.date = date
        self.dayKey = DayKey.make(from: date)
        self.name = name
        self.focusRaw = focus.rawValue
    }

    var isLive: Bool { liveStartedAt != nil && liveEndedAt == nil }

    var liveDuration: TimeInterval? {
        guard let start = liveStartedAt else { return nil }
        return (liveEndedAt ?? .now).timeIntervalSince(start)
    }

    var orderedExercises: [ExerciseEntry] {
        exercises.sorted { $0.orderIndex < $1.orderIndex }
    }

    var totalVolumeKg: Double {
        exercises.reduce(0) { $0 + $1.volumeKg }
    }

    var totalSetCount: Int {
        exercises.reduce(0) { $0 + $1.sets.count }
    }

    var hasContent: Bool { !exercises.isEmpty || !name.isEmpty }

    var allSets: [SetEntry] { exercises.flatMap(\.sets) }

    var totalSeconds: Int { allSets.reduce(0) { $0 + ($1.durationSec ?? 0) } }

    var totalMeters: Double { allSets.reduce(0) { $0 + ($1.distanceMeters ?? 0) } }

    /// The heaviest working set that also has reps — "315 x 3" is the number a
    /// strength day is remembered by, and a weight with no reps is not a set.
    /// Warmups are excluded, consistent with `volumeKg`.
    var topSet: SetEntry? {
        allSets
            .filter { !$0.isWarmup && $0.weightKg > 0 && $0.reps > 0 }
            .max { $0.weightKg < $1.weightKg }
    }

    /// The one line under a day's name.
    ///
    /// Volume is the wrong answer for four of the six focuses: a Hyrox day's
    /// number is metres and minutes, and a top single is the point of a
    /// powerlifting day. Matches Android and the browser, which carry the same
    /// rules — a coach reading a log should see what the athlete saw — except
    /// that weight is rendered in the user's own unit here, which the other
    /// two, being pounds-native, have no equivalent of.
    ///
    /// Every branch falls back to the plain set count when the day holds
    /// nothing of its kind, so an endurance focus over a weights-only day
    /// reads "2 sets" rather than "2 sets - 0 m".
    func summary(unit: WeightUnit, focus: TrainingFocus? = nil) -> String {
        let count = "\(totalSetCount) \(totalSetCount == 1 ? "set" : "sets")"

        switch (focus ?? self.focus).summary {
        case .topSet:
            guard let best = topSet else { return count }
            let weight = unit.fromKilograms(best.weightKg)
            let weightText = weight == weight.rounded()
                ? String(Int(weight)) : String(format: "%.1f", weight)
            return "\(count) - top \(weightText) x \(best.reps)"

        case .work:
            guard totalSeconds > 0 else { return count }
            return "\(count) - \(SetMetrics.clock(totalSeconds)) working"

        case .distance:
            var parts = [count]
            if totalMeters > 0 { parts.append(SetMetrics.distance(totalMeters)) }
            if totalSeconds > 0 { parts.append(SetMetrics.clock(totalSeconds)) }
            return parts.joined(separator: " - ")

        case .volume:
            guard totalVolumeKg > 0 else { return count }
            let volume = Int(unit.fromKilograms(totalVolumeKg))
            return "\(count) - \(volume) \(unit.abbreviation) volume"
        }
    }
}

/// Formatting shared by the day summary and the set editor. Free of SwiftUI
/// and SwiftData so it can be tested directly, and matching Android's
/// `FocusMetrics.kt` label for label.
enum SetMetrics {

    /// mm:ss, or h:mm:ss once it runs past an hour.
    static func clock(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// Metres are the stored unit; km reads better past a kilometre.
    static func distance(_ meters: Double) -> String {
        meters >= 1000
            ? String(format: "%.2f km", meters / 1000)
            : "\(Int(meters.rounded())) m"
    }

    /// Accepts "90", "1:30" or "1:30:00" and returns seconds. Nil for anything
    /// that isn't a duration, so a half-typed field doesn't store a zero.
    static func parseDuration(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }
        var total = 0
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }
}

@Model
final class ExerciseEntry {
    var id: UUID = UUID()

    var exerciseRefID: String = ""
    // Snapshot fields — history must not change when reference data updates.
    var name: String = ""
    var primaryMuscle: String?
    var equipment: String?

    var orderIndex: Int = 0
    var day: WorkoutDay?

    @Relationship(deleteRule: .cascade, inverse: \SetEntry.exercise)
    var sets: [SetEntry] = []

    init(exerciseRefID: String, name: String, orderIndex: Int,
         primaryMuscle: String? = nil, equipment: String? = nil) {
        self.id = UUID()
        self.exerciseRefID = exerciseRefID
        self.name = name
        self.orderIndex = orderIndex
        self.primaryMuscle = primaryMuscle
        self.equipment = equipment
    }

    /// "Deadlift (Barbell)" — equipment in parentheses, as on Android.
    var displayName: String {
        guard let equipment, !equipment.isEmpty else { return name }
        return "\(name) (\(equipment.capitalized))"
    }

    var orderedSets: [SetEntry] {
        sets.sorted { $0.orderIndex < $1.orderIndex }
    }

    var volumeKg: Double {
        sets.reduce(0) { $0 + $1.volumeKg }
    }
}

@Model
final class SetEntry {
    var id: UUID = UUID()
    var orderIndex: Int = 0

    /// Canonical kilograms regardless of what the user sees. Mixed-unit
    /// history is unrecoverable once it happens.
    var weightKg: Double = 0
    var reps: Int = 0

    /// Rate of perceived exertion, 6–10 in half steps. First-class here
    /// because the Android app shows it inline on every set.
    var rpe: Double?

    var isWarmup: Bool = false
    var completedAt: Date?
    var exercise: ExerciseEntry?

    /// A set is not always a weight for reps. A sled push is 25 metres, a ski
    /// erg interval is 90 seconds, and before V6 this app could record neither
    /// — which is why its CrossFit, Hyrox and endurance focuses had nothing to
    /// show. Both optional: a barbell set has neither, and absent is not zero.
    ///
    /// Metres are canonical, as on Android, and converted only for display.
    var durationSec: Int?
    var distanceMeters: Double?

    init(orderIndex: Int, weightKg: Double = 0, reps: Int = 0,
         rpe: Double? = nil, isWarmup: Bool = false,
         durationSec: Int? = nil, distanceMeters: Double? = nil) {
        self.id = UUID()
        self.orderIndex = orderIndex
        self.weightKg = weightKg
        self.reps = reps
        self.rpe = rpe
        self.isWarmup = isWarmup
        self.durationSec = durationSec
        self.distanceMeters = distanceMeters
    }

    var volumeKg: Double {
        isWarmup ? 0 : Double(reps) * weightKg
    }

    /// "325 x 5 @7.5", "1:30", "25 m", or any combination — whatever the set
    /// actually holds, regardless of the focus it is being viewed under. A set
    /// logged as a sled push stays legible on a bodybuilding day; hiding a
    /// field in the editor must not hide the number already in it.
    ///
    /// Matches Android's `formatSet`, which orders the same way.
    func display(unit: WeightUnit) -> String {
        var parts: [String] = []

        if weightKg > 0 || reps > 0 {
            let weight = unit.fromKilograms(weightKg)
            let weightText = weight == weight.rounded()
                ? String(Int(weight))
                : String(format: "%.1f", weight)
            parts.append("\(weightText) x \(reps)")
        }
        if let rpe {
            let rpeText = rpe == rpe.rounded() ? String(Int(rpe)) : String(format: "%.1f", rpe)
            parts.append("@\(rpeText)")
        }
        if let durationSec { parts.append(SetMetrics.clock(durationSec)) }
        if let distanceMeters { parts.append(SetMetrics.distance(distanceMeters)) }

        return parts.isEmpty ? "-" : parts.joined(separator: " ")
    }

    /// Epley. Only meaningful in the 1–10 rep range.
    var estimatedOneRepMaxKg: Double? {
        guard reps > 0, weightKg > 0, !isWarmup else { return nil }
        return weightKg * (1 + Double(reps) / 30.0)
    }
}

@Model
final class BodyMeasurement {
    var id: UUID = UUID()
    var recordedAt: Date = Date.now
    var dayKey: String = ""
    var weightKg: Double?
    var bodyFatPercent: Double?
    var healthKitUUID: UUID?

    init(recordedAt: Date = .now, weightKg: Double? = nil, bodyFatPercent: Double? = nil) {
        self.id = UUID()
        self.recordedAt = recordedAt
        self.dayKey = DayKey.make(from: recordedAt)
        self.weightKg = weightKg
        self.bodyFatPercent = bodyFatPercent
    }
}

// MARK: - Queries

enum WorkoutQueries {
    static func day(_ dayKey: String) -> FetchDescriptor<WorkoutDay> {
        var descriptor = FetchDescriptor<WorkoutDay>(
            predicate: #Predicate { $0.dayKey == dayKey }
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    static func recent(limit: Int = 30) -> FetchDescriptor<WorkoutDay> {
        var descriptor = FetchDescriptor<WorkoutDay>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Fetches the day record, creating it if this is the first entry for it.
    @MainActor
    static func fetchOrCreate(_ date: Date, in context: ModelContext) -> WorkoutDay {
        let key = DayKey.make(from: date)
        if let existing = try? context.fetch(day(key)).first {
            return existing
        }
        let created = WorkoutDay(date: date)
        context.insert(created)
        return created
    }
}
