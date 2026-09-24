import Foundation
import CryptoKit
import SwiftData
import LiftCore
import LiftSync

// Storing a workout the watch logged, as an ordinary workout.
//
// Free of any view and of `WCSession`, for the reason `WatchPlanBuilder` is:
// this decides what happens to somebody's training when two devices disagree,
// and a rule inside a delegate callback cannot be tested. `WatchSyncReceiver`
// is the only caller.

/// What happened to one `SESSION_FINISHED`.
enum WatchSessionOutcome: Equatable {
    /// The session was stored: a new workout, or a newer revision replacing
    /// what this phone had imported before.
    case stored
    /// Already stored at this revision or a newer one. Nothing changed, and
    /// the watch is acknowledged again — the first acknowledgement may be
    /// the thing that was lost.
    case duplicate
    /// A newer revision arrived for a session whose rows this phone has
    /// edited since importing them. **The phone's version is kept**, and the
    /// watch's edit is dropped rather than overwriting it.
    case conflict
    /// Nothing to store: an envelope with no `session` payload (a watch
    /// build that predates it), or one carrying no sets at all.
    case nothingToStore
    /// The store refused the write. Nothing was changed, and nothing is
    /// acknowledged: until the acknowledgement, the watch keeps the only
    /// other copy.
    case failed
}

enum WatchSessionImporter {

    /// How far the phone will follow the watch's own idea of what day it is.
    ///
    /// The watch stamps `performedOn` from its own clock, and two clocks are
    /// not comparable — which is the whole reason this contract reconciles
    /// on `revision`. A queued session is normally minutes late and at worst
    /// days late, so a claimed day inside this window is believed exactly as
    /// sent; one outside it is a clock, not a calendar, and the session is
    /// filed under the phone's own today instead.
    ///
    /// Never dropped, in either case. A workout filed under the wrong year is
    /// a workout the lifter never finds again, which is the failure this
    /// guards against; refusing to store it would be worse than both.
    static let maxBackdatedDays = 14
    /// One day forward, not zero: a phone and a watch in different time zones
    /// legitimately disagree about the date for a few hours.
    static let maxForwardDays = 1

    // MARK: - Importing

    @MainActor
    @discardableResult
    static func apply(_ envelope: SyncEnvelope, in context: ModelContext,
                      now: Date = .now, calendar: Calendar = .current,
                      defaults: UserDefaults = .standard) -> WatchSessionOutcome {
        guard envelope.event == .sessionFinished, let session = envelope.session else {
            return .nothingToStore
        }
        let exercises = session.exercises.filter { !$0.sets.isEmpty }
        guard !exercises.isEmpty else { return .nothingToStore }

        var receipts = WatchSessionImports.load(from: defaults)

        // Seen before, at this revision or a newer one: a resend, or a queued
        // copy arriving after the live one. Storing it again would double
        // every set.
        if let receipt = receipts.receipt(for: envelope.workoutID),
           receipt.revision >= envelope.revision {
            return .duplicate
        }

        let fingerprint = self.fingerprint(of: exercises)

        // Seen before, at an older revision: the watch edited the session
        // after finishing it. The rows this phone wrote for it are replaced,
        // but only if they are still exactly as they were written — see
        // `replaceable(_:in:)`.
        if let receipt = receipts.receipt(for: envelope.workoutID) {
            guard let day = day(receipt.dayID, in: context),
                  let existing = replaceable(receipt, in: day) else {
                // The phone has edited, deleted or moved what the watch sent.
                // The phone wins: a newer edit on the device the lifter is
                // looking at is not something a watch may silently undo. The
                // revision is recorded so the same envelope is not weighed up
                // again on every resend, and the watch is acknowledged so it
                // stops holding a session this phone has decided about.
                receipts.record(WatchSessionImports.Receipt(
                    revision: envelope.revision, dayID: receipt.dayID,
                    exerciseIDs: receipt.exerciseIDs, fingerprint: receipt.fingerprint
                ), for: envelope.workoutID)
                receipts.save(to: defaults)
                return .conflict
            }
            for entry in existing { context.delete(entry) }
            let ids = insert(exercises, into: day, sessionID: envelope.workoutID,
                             defaults: defaults)
            guard save(context) else { return .failed }
            receipts.record(WatchSessionImports.Receipt(
                revision: envelope.revision, dayID: day.id,
                exerciseIDs: ids, fingerprint: fingerprint
            ), for: envelope.workoutID)
            receipts.save(to: defaults)
            return .stored
        }

        // Never seen. The day is found or created and the session's
        // exercises are **appended** to it: a day is the unit of record and
        // may already hold a workout logged on the phone, or an earlier
        // session from the watch, and neither is replaced by this one.
        let date = self.date(for: session, now: now, calendar: calendar)
        let day = WorkoutQueries.fetchOrCreate(date, in: context)
        if day.name.trimmingCharacters(in: .whitespaces).isEmpty {
            day.name = session.name
        }
        if let focus = TrainingFocus.decode(session.focus ?? ""), day.exercises.isEmpty {
            // Only for a day this session is the first thing on: a day the
            // lifter has already logged against has a focus they chose.
            day.focus = focus
        }
        let ids = insert(exercises, into: day, sessionID: envelope.workoutID,
                         defaults: defaults)
        guard save(context) else { return .failed }
        receipts.record(WatchSessionImports.Receipt(
            revision: envelope.revision, dayID: day.id,
            exerciseIDs: ids, fingerprint: fingerprint
        ), for: envelope.workoutID)
        receipts.save(to: defaults)
        return .stored
    }

    // MARK: - Which day

    /// The date to file the session under. See `maxBackdatedDays`.
    static func date(for session: FinishedSession, now: Date,
                     calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        guard let claimed = parse(session.performedOn, calendar: calendar) else { return now }
        // Day arithmetic through `Calendar`, never seconds: subtracting
        // 86,400 repeats a day across a DST fall-back.
        let distance = calendar.dateComponents([.day], from: today, to: claimed).day ?? 0
        guard distance <= maxForwardDays, distance >= -maxBackdatedDays else { return now }

        // The exact moment, when this phone's calendar reads it as the same
        // day the watch claimed — which is the ordinary case, and keeps the
        // real time of day rather than a synthesised one.
        if DayKey.make(from: session.startedAt) == session.performedOn { return session.startedAt }
        return claimed
    }

    /// Noon, so the stored date cannot land on a day that has no midnight
    /// (DST forward jumps in some zones) or slip across one.
    private static func parse(_ dayKey: String, calendar: Calendar) -> Date? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1],
                                                  day: parts[2], hour: 12))
    }

    // MARK: - Writing

    /// Appends the session's exercises to `day` and returns the ids written,
    /// in order, for the receipt.
    @MainActor
    private static func insert(_ exercises: [PerformedExercise], into day: WorkoutDay,
                               sessionID: UUID, defaults: UserDefaults) -> [UUID] {
        var ids: [UUID] = []
        var perSide = PerSideLogging.decode(defaults.string(forKey: PerSideLogging.storageKey) ?? "{}")
        var perSideChanged = false

        for (index, exercise) in exercises.enumerated() {
            let entry = ExerciseEntry(
                // The same shape `RoutineSession` writes ("routine:<id>"):
                // the reference id of a lift the watch named is not
                // knowable here — a plan carries no exercise ids — and
                // inventing a match against reference data would put a
                // wrong id on somebody's history. Name and equipment are
                // snapshotted, which is what every reader actually groups on.
                exerciseRefID: "watch:\(sessionID.uuidString):\(index)",
                name: exercise.name,
                orderIndex: day.exercises.count,
                equipment: exercise.equipment?.isEmpty == false ? exercise.equipment : nil
            )
            entry.sets = exercise.sets.enumerated().map { position, set in
                let stored = SetEntry(
                    orderIndex: position,
                    // Kilograms on both sides of this wire and in the store:
                    // nothing here converts, and nothing here may.
                    weightKg: set.weightKg.isFinite ? max(0, set.weightKg) : 0,
                    reps: max(0, set.reps),
                    rpe: set.rpe,
                    isWarmup: set.isWarmup,
                    side: set.side?.setSide
                )
                stored.completedAt = set.completedAt
                return stored
            }
            day.exercises.append(entry)
            ids.append(entry.id)

            // A lift the watch logged one limb at a time is a lift this
            // phone should ask about one limb at a time. Only when the
            // lifter has never answered for it: an explicit "no" here is an
            // answer about this app's own set row and outranks a guess —
            // including this one.
            if exercise.sets.contains(where: { $0.side != nil }) {
                let key = ExerciseKey.make(name: exercise.name, equipment: exercise.equipment)
                if perSide[key] == nil {
                    perSide[key] = true
                    perSideChanged = true
                }
            }
        }

        if perSideChanged {
            defaults.set(PerSideLogging.encode(perSide), forKey: PerSideLogging.storageKey)
        }
        return ids
    }

    @MainActor
    private static func save(_ context: ModelContext) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            // One `save()`: a failure rolls the whole session back, so there
            // is no half-stored workout, and the caller does not acknowledge.
            context.rollback()
            return false
        }
    }

    // MARK: - Replacing an earlier import

    @MainActor
    private static func day(_ id: UUID, in context: ModelContext) -> WorkoutDay? {
        var descriptor = FetchDescriptor<WorkoutDay>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// The entries an earlier import of this session wrote, **only** if every
    /// one of them is still there and still holds exactly what was written.
    ///
    /// This is what makes "the watch never silently overwrites newer phone
    /// edits" true in code rather than in a comment: the fingerprint is taken
    /// at import time and re-derived here, so a set the lifter corrected on
    /// the phone, an exercise they deleted, or a whole day they rebuilt all
    /// read as "not replaceable", and the newer revision is refused.
    @MainActor
    private static func replaceable(_ receipt: WatchSessionImports.Receipt,
                                    in day: WorkoutDay) -> [ExerciseEntry]? {
        var entries: [ExerciseEntry] = []
        for id in receipt.exerciseIDs {
            guard let entry = day.exercises.first(where: { $0.id == id }) else { return nil }
            entries.append(entry)
        }
        guard fingerprint(ofStored: entries) == receipt.fingerprint else { return nil }
        return entries
    }

    // MARK: - Fingerprints

    /// A stable summary of what was imported, so a later revision can tell
    /// "nobody has touched this" from "the lifter has edited it here".
    ///
    /// Deliberately content, not a timestamp: `ExerciseEntry` and `SetEntry`
    /// have no `updatedAt`, and adding one is a schema change for a store two
    /// shipped apps share.
    static func fingerprint(of exercises: [PerformedExercise]) -> String {
        digest(exercises.map { exercise in
            line(name: exercise.name, equipment: exercise.equipment,
                 sets: exercise.sets.map {
                     setLine(weightKg: $0.weightKg, reps: $0.reps, rpe: $0.rpe,
                             isWarmup: $0.isWarmup, side: $0.side?.setSide)
                 })
        })
    }

    @MainActor
    static func fingerprint(ofStored entries: [ExerciseEntry]) -> String {
        digest(entries.map { entry in
            line(name: entry.name, equipment: entry.equipment,
                 sets: entry.orderedSets.map {
                     setLine(weightKg: $0.weightKg, reps: $0.reps, rpe: $0.rpe,
                             isWarmup: $0.isWarmup, side: $0.side)
                 })
        })
    }

    private static func line(name: String, equipment: String?, sets: [String]) -> String {
        "\(ExerciseKey.make(name: name, equipment: equipment))#\(sets.joined(separator: ";"))"
    }

    /// Weight to three decimals and RPE to one: the numbers that survive a
    /// JSON round trip. Comparing raw `Double` bit patterns would call an
    /// untouched set edited.
    private static func setLine(weightKg: Double, reps: Int, rpe: Double?,
                                isWarmup: Bool, side: SetSide?) -> String {
        let weight = String(format: "%.3f", weightKg.isFinite ? weightKg : 0)
        let rpeText = rpe.map { String(format: "%.1f", $0) } ?? "-"
        return "\(weight)/\(reps)/\(rpeText)/\(isWarmup ? "w" : "-")/\(side?.rawValue ?? "-")"
    }

    private static func digest(_ lines: [String]) -> String {
        let data = Data(lines.joined(separator: "\n").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Sides, in this app's own spelling

extension PlanSide {
    /// The inverse of `SetSide.planSide`. Two types, identical raw values,
    /// deliberately: `SetSide` is this app's own (it is in `Sources/Shared`,
    /// which the widget compiles) and `PlanSide` is `LiftSync`'s, which both
    /// apps compile.
    var setSide: SetSide { self == .left ? .left : .right }
}

// MARK: - What this phone has already stored

/// One record per watch session this phone has imported: the revision it was
/// imported at, the day and the rows it produced, and a fingerprint of what
/// was written.
///
/// `UserDefaults` rather than columns on the store, for the reason
/// `WatchSessionHeartRateStore` and `PlanSides` are there too: `WorkoutDay`
/// and `ExerciseEntry` are shared `@Model`s, and a field on one is a schema
/// change for two shipped apps. This is bookkeeping about a wire, not
/// history: losing it costs a duplicate import of a session the watch is
/// still resending, and nothing at all otherwise.
struct WatchSessionImports: Codable, Equatable {

    struct Receipt: Codable, Equatable {
        var revision: Int
        var dayID: UUID
        var exerciseIDs: [UUID]
        var fingerprint: String
    }

    static let defaultsKey = "watchSessionImports"
    /// Sessions, not days. A watch logs at most a handful a day, so this is
    /// years; the cap exists only so the record cannot grow for ever.
    static let capacity = 500

    private(set) var receipts: [String: Receipt] = [:]
    /// Insertion order, so the cap drops the oldest rather than an arbitrary
    /// dictionary member.
    private(set) var order: [String] = []

    func receipt(for sessionID: UUID) -> Receipt? { receipts[sessionID.uuidString] }

    mutating func record(_ receipt: Receipt, for sessionID: UUID) {
        let key = sessionID.uuidString
        if receipts[key] == nil { order.append(key) }
        receipts[key] = receipt
        if order.count > Self.capacity {
            for stale in order.prefix(order.count - Self.capacity) { receipts[stale] = nil }
            order = Array(order.suffix(Self.capacity))
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> WatchSessionImports {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(WatchSessionImports.self, from: data)
        else { return WatchSessionImports() }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
