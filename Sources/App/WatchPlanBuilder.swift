import Foundation
import CryptoKit
import SwiftData
import LiftCore
import LiftSync

// Everything the phone needs to decide *which* plan to push and under what
// revision. The wire types themselves (`WorkoutPlan`, `PlanExercise`,
// `PrescribedSet`, `LastPerformed`) are `LiftSync`'s, in
// Watch/LiftWatchKit: the same definitions the watch decodes with. Nothing
// here is needed by the widget target, so nothing here is compiled into it.

// MARK: - Building today's plan

/// The plan to push, and the id to push it under.
struct PushablePlan: Equatable {
    /// The envelope's `workoutId`. The routine's own id, so re-pushing the
    /// same routine is recognised as the same plan rather than a new one.
    var id: UUID
    var plan: WorkoutPlan
}

/// Turns what the phone knows — routines, a coach's scheduled sessions, and
/// training history — into the plan the watch runs.
///
/// Free of any view and of `WCSession`, so the rules below are testable:
/// which plan today has, what a partial prescription turns into on the wire,
/// and where "last time's actual" comes from. `WatchSyncReceiver` is the only
/// caller that actually sends one.
enum WatchPlanBuilder {

    /// What the watch falls back to when a set prescribes no rest, matching
    /// `RestTimer`'s own default on that side. Stated here only so the
    /// Settings stepper has a sensible starting value; the wire never
    /// carries "the default", it carries a real number or nothing.
    static let defaultRestSeconds = 90

    /// Today's plan, or `nil` when there is none — which is not a failure.
    /// A day with no plan is the watch's free-entry flow, unchanged.
    ///
    /// Resolution order, most explicit first:
    /// 1. A routine the lifter sent to the watch by hand today
    ///    (`WatchPlanPin`). A pin is for one day; yesterday's is ignored
    ///    rather than followed into today.
    /// 2. A `ScheduledSession` a coach's plan link booked for today.
    @MainActor
    static func todaysPlan(
        on date: Date = .now,
        in context: ModelContext,
        restSeconds: Int? = nil,
        defaults: UserDefaults = .standard
    ) -> PushablePlan? {
        let dayKey = DayKey.make(from: date)

        var chosen: (routine: Routine, source: WorkoutPlan.Source)?

        if let pin = WatchPlanPin.load(from: defaults), pin.dayKey == dayKey,
           let routine = routine(pin.routineID, in: context) {
            chosen = (routine, .routine)
        }

        if chosen == nil {
            let descriptor = FetchDescriptor<ScheduledSession>(
                predicate: #Predicate { $0.dayKey == dayKey },
                sortBy: [SortDescriptor(\.scheduledFor)]
            )
            if let session = try? context.fetch(descriptor).first,
               let routine = routine(session.routineID, in: context) {
                chosen = (routine, .coachPlan)
            }
        }

        guard let chosen else { return nil }

        // 60 days is far more history than "last time" needs, and cheap: the
        // fetch is one day-ordered descriptor, and the match below stops at
        // the first day that holds the exercise.
        let history = (try? context.fetch(WorkoutQueries.recent(limit: 60))) ?? []

        return PushablePlan(
            id: chosen.routine.id,
            plan: plan(
                from: chosen.routine,
                source: chosen.source,
                scheduledFor: date,
                restSeconds: restSeconds,
                history: history,
                excludingDayKey: dayKey,
                sides: PlanSides.load(from: defaults)
            )
        )
    }

    /// `sides` is the coach's per-side prescription for this routine
    /// (`PlanSides`), which lives in `UserDefaults` rather than on LiftKit's
    /// shared routine models — so it has to be handed in here rather than
    /// read off the `Routine`. A routine nobody has prescribed sides on
    /// yields the empty value and a plan identical to the one this built
    /// before any of this existed.
    @MainActor
    static func plan(
        from routine: Routine,
        source: WorkoutPlan.Source,
        scheduledFor: Date?,
        restSeconds: Int?,
        history: [WorkoutDay],
        excludingDayKey: String? = nil,
        sides: PlanSides = PlanSides()
    ) -> WorkoutPlan {
        let exercises = routine.orderedExercises.map { exercise -> PlanExercise in
            PlanExercise(
                name: exercise.name,
                equipment: exercise.equipment.isEmpty ? nil : exercise.equipment,
                note: exercise.note,
                sets: exercise.orderedSets.map { prescribed in
                    // Straight across, nil for nil. A routine's targets are
                    // already kilograms (`RoutinePrescribedSet`'s contract),
                    // and the wire field is `weightKg`, so there is no
                    // conversion here and there must not be one.
                    PrescribedSet(
                        weightKg: prescribed.targetWeightKg,
                        reps: prescribed.targetReps,
                        rpe: prescribed.targetRPE,
                        restSeconds: restSeconds,
                        side: sides.side(of: prescribed)?.planSide
                    )
                },
                lastPerformed: lastPerformed(
                    name: exercise.name,
                    equipment: exercise.equipment,
                    in: history,
                    excludingDayKey: excludingDayKey
                ),
                eachSide: sides.isEachSide(exercise)
            )
        }
        return WorkoutPlan(
            name: routine.name,
            source: source,
            scheduledFor: scheduledFor.map { DayKey.make(from: $0) },
            exercises: exercises
        )
    }

    /// The most recent real set of this exercise, on any earlier day.
    ///
    /// Matched on name *and* equipment, because a cable pulldown and a
    /// machine pulldown are not the same lift. Warmups are skipped, and a
    /// zero weight or zero reps travels as nothing at all rather than as a
    /// zero — the same "blank stays blank" rule the prescription follows.
    static func lastPerformed(
        name: String,
        equipment: String?,
        in history: [WorkoutDay],
        excludingDayKey: String? = nil
    ) -> LastPerformed? {
        let wanted = matchKey(name: name, equipment: equipment)
        for day in history.sorted(by: { $0.date > $1.date }) {
            if let excludingDayKey, day.dayKey == excludingDayKey { continue }
            guard let entry = day.orderedExercises.first(where: {
                matchKey(name: $0.name, equipment: $0.equipment) == wanted
            }) else { continue }
            guard let set = entry.orderedSets.last(where: {
                !$0.isWarmup && ($0.reps > 0 || $0.weightKg > 0)
            }) else { continue }
            return LastPerformed(
                weightKg: set.weightKg > 0 ? set.weightKg : nil,
                reps: set.reps > 0 ? set.reps : nil,
                rpe: set.rpe,
                performedOn: day.dayKey
            )
        }
        return nil
    }

    /// `"bench press|barbell"` — the same name-and-equipment identity the
    /// rest of the app groups lifts by, lowercased and trimmed so that a
    /// routine written "Bench Press" matches history logged "bench press".
    static func matchKey(name: String, equipment: String?) -> String {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanEquipment = (equipment ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(cleanName)|\(cleanEquipment)"
    }

    @MainActor
    private static func routine(_ id: UUID, in context: ModelContext) -> Routine? {
        var descriptor = FetchDescriptor<Routine>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

// MARK: - Sides, in the watch's own spelling

extension SetSide {
    /// The same two words on the watch's wire. Two types rather than one
    /// because `SetSide` is this app's own (it is in `Sources/Shared`, which
    /// the widget compiles too) and `PlanSide` is `LiftSync`'s, which both
    /// apps compile; the raw values are identical, deliberately, so a side
    /// means one thing in the store, in a backup and on this wire.
    var planSide: PlanSide { self == .left ? .left : .right }
}

// MARK: - Which routine the lifter sent

/// A routine the lifter pushed to the watch by hand, for one day.
///
/// Deliberately not a field on `Routine`: that is a `LiftKit` `@Model` shared
/// with Coach, so a property there is a schema change for two shipped apps —
/// the same trade Coach makes for `cookPlanOwners`. This is one small,
/// day-scoped preference, and `UserDefaults` is the right size for it.
struct WatchPlanPin: Codable, Equatable {
    var routineID: UUID
    /// The day the pin is for. A pin does not survive into tomorrow: the
    /// lifter said "run this today", not "run this from now on".
    var dayKey: String

    static let defaultsKey = "watchPlanPin"

    static func load(from defaults: UserDefaults = .standard) -> WatchPlanPin? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(WatchPlanPin.self, from: data)
    }

    static func save(routineID: UUID, on date: Date = .now, to defaults: UserDefaults = .standard) {
        let pin = WatchPlanPin(routineID: routineID, dayKey: DayKey.make(from: date))
        guard let data = try? JSONEncoder().encode(pin) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

// MARK: - Revisions

/// The revision number each plan is pushed under.
///
/// The schema's conflict rule is "newer revision wins", so a plan needs a
/// number that only ever goes up — and one that does *not* go up when nothing
/// changed, or every launch would look like a new plan to a watch that
/// already has it. So: hash the payload, bump only when the hash differs from
/// the last one sent under that id.
///
/// A counter rather than a timestamp deliberately. `updatedAt` is already on
/// the envelope and already a wall clock; the whole reason this contract
/// reconciles on `revision` is that two devices' clocks are not comparable.
struct WatchPlanRevisions: Codable, Equatable {

    struct Entry: Codable, Equatable {
        var revision: Int
        var contentHash: String
    }

    private(set) var entries: [String: Entry] = [:]

    static let defaultsKey = "watchPlanRevisions"

    /// The revision to send this plan under: the one it already had if the
    /// content is unchanged, the next one up if it changed or is new.
    /// Revisions start at 1, which the schema's `minimum` requires.
    mutating func revision(for id: UUID, contentHash: String) -> Int {
        let key = id.uuidString
        guard let existing = entries[key] else {
            entries[key] = Entry(revision: 1, contentHash: contentHash)
            return 1
        }
        if existing.contentHash == contentHash { return existing.revision }
        let next = existing.revision + 1
        entries[key] = Entry(revision: next, contentHash: contentHash)
        return next
    }

    /// SHA-256 of the payload with its keys sorted, for the same reason
    /// `PlanImporter.hash(of:)` sorts: a synthesised `encode(to:)` promises
    /// no key order, and an unstable hash would bump the revision on every
    /// push and re-send a plan the watch already has.
    static func contentHash(of plan: WorkoutPlan) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(plan) else { return UUID().uuidString }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func load(from defaults: UserDefaults = .standard) -> WatchPlanRevisions {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(WatchPlanRevisions.self, from: data)
        else { return WatchPlanRevisions() }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

// MARK: - Settings

/// The one preference the guided session adds to the phone.
///
/// A routine's prescribed sets carry weight, reps and RPE but no rest —
/// neither `RoutinePrescribedSet` nor PLAN-FORMAT's set tuple has a field for
/// it — so without this the watch would have nothing to start its timer at
/// but its own 90-second default, and "rest starts at the prescribed seconds"
/// would be a prescription nobody wrote. One number, set once, sent with
/// every set.
enum WatchPlanSettings {
    static let restSecondsKey = "watchRestSeconds"
    /// Matches `RestTimer`'s own default on the watch, so the stepper starts
    /// where the watch already is.
    static let defaultRestSeconds = 90
    static let restSecondsRange = 30...300
    static let restSecondsStep = 15

    /// What to put on every prescribed set, or `nil` for "say nothing and
    /// let the watch use its own default".
    ///
    /// `UserDefaults.integer(forKey:)` cannot tell "never set" from "set to
    /// zero", and never-set is the normal case: the Settings stepper's
    /// `@AppStorage` default only reaches disk once someone opens that
    /// screen and moves it. Reading that as zero would push every set with
    /// no rest at all, and rest would never start on its own for anyone who
    /// had not been into Settings — so missing means the default, and only
    /// a real, stored non-positive value means "nothing".
    static func resolvedRestSeconds(in defaults: UserDefaults = .standard) -> Int? {
        guard defaults.object(forKey: restSecondsKey) != nil else { return defaultRestSeconds }
        let stored = defaults.integer(forKey: restSecondsKey)
        return stored > 0 ? stored : nil
    }
}

// MARK: - Session heart rate, as it arrives

/// What the watch reported for its last finished lifting session.
///
/// `UserDefaults` rather than the SwiftData store on purpose: `WorkoutDay`
/// has no heart-rate columns, and adding them is a schema change for a store
/// two shipped apps share. The samples are in HealthKit already — the watch
/// writes them as part of its own workout — so this is only the summary,
/// kept so a phone screen can show it without reading Health back.
enum WatchSessionHeartRateStore {
    static let defaultsKey = "lastWatchSessionHeartRate"

    struct Record: Codable, Equatable {
        var workoutID: UUID
        var averageBpm: Double
        var maxBpm: Double
        var receivedAt: Date
    }

    static func record(_ heartRate: SessionHeartRate, for workoutID: UUID,
                       at date: Date = .now, in defaults: UserDefaults = .standard) {
        let record = Record(
            workoutID: workoutID,
            averageBpm: heartRate.averageBpm,
            maxBpm: heartRate.maxBpm,
            receivedAt: date
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func latest(in defaults: UserDefaults = .standard) -> Record? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }
}
