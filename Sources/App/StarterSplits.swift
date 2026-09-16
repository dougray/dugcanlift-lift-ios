import Foundation
import SwiftData
import LiftCore

/// Ready-made routines — push/pull/legs, upper/lower, full body, mobility,
/// active rest and two runs — for someone who hasn't written any of their own.
///
/// These waited on the exercise library for a concrete reason rather than a
/// tidy one. A split is a list of exercise names, and a name that doesn't
/// match what the app searches produces history that lines up with nothing:
/// no previous-set lookup, no trend line, no agreement with a coach. Every
/// name in `splits.json` exists verbatim in the reference library, and a test
/// checks all of them against the shipped `exercises.db` rather than trusting
/// the file.
///
/// It is the same `splits.json` LIFT for Android bundles. Copy it from
/// `dugcanlift-site/lift/` rather than editing it here.
struct StarterSplit: Identifiable, Equatable {
    let folder: String
    let name: String
    let exercises: [Exercise]

    /// Stable across reads — folder and name are what identify a split, and
    /// what [`isAlreadySaved`](x-source-tag://isAlreadySaved) matches on.
    var id: String { "\(folder)|\(name)" }

    struct Exercise: Equatable {
        let name: String
        let equipment: String
        /// How many prescribed sets to create. iOS models each set as its own
        /// object, so the file's `sets: 4` becomes four of them — Android
        /// keeps a count instead, which is why this is expanded here and not
        /// in the shared file.
        let sets: Int
        let reps: Int?
        let durationSec: Int?
    }

    var setCount: Int { exercises.reduce(0) { $0 + $1.sets } }

    /// "Barbell Squat, Leg Press, Lying Leg Curls" — names only. The full
    /// `displayName` list is a paragraph at library name lengths.
    var preview: String { exercises.map(\.name).joined(separator: ", ") }
}

enum StarterSplits {

    static let resourceName = "splits"

    /// Reads the bundled splits. A missing or broken file costs the starter
    /// list and nothing else — writing your own routine is the path that
    /// already worked.
    static func bundled(in bundle: Bundle = .main) -> [StarterSplit] {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return decode(data)
    }

    /// Separate from `bundled` so a test can drive it with bytes rather than a
    /// bundle. A malformed routine is skipped, not thrown: one bad entry
    /// should cost that split, not the list.
    static func decode(_ data: Data) -> [StarterSplit] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["routines"] as? [[String: Any]] else { return [] }

        return rows.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }

            let exercises = (row["exercises"] as? [[String: Any]] ?? []).compactMap { entry -> StarterSplit.Exercise? in
                guard let exerciseName = entry["name"] as? String, !exerciseName.isEmpty else { return nil }
                return StarterSplit.Exercise(
                    name: exerciseName,
                    equipment: entry["equipment"] as? String ?? "",
                    sets: entry["sets"] as? Int ?? 3,
                    reps: entry["reps"] as? Int,
                    durationSec: entry["durationSec"] as? Int
                )
            }
            guard !exercises.isEmpty else { return nil }

            return StarterSplit(
                folder: row["folder"] as? String ?? "",
                name: name,
                exercises: exercises
            )
        }
    }

    /// Whether this starter is already among `routines`.
    ///
    /// Matched on folder and name rather than id, because adding one makes a
    /// copy with its own identity by design. Someone who renamed their copy
    /// gets the starter offered again, which is the right way round: the
    /// alternative is a starter that vanishes because of an edit they made to
    /// something else.
    ///
    /// - Tag: isAlreadySaved
    static func isAlreadySaved(_ split: StarterSplit, in routines: [Routine]) -> Bool {
        routines.contains {
            $0.name.compare(split.name, options: .caseInsensitive) == .orderedSame &&
            $0.folder.compare(split.folder, options: .caseInsensitive) == .orderedSame
        }
    }

    /// Copies a starter into the store as an ordinary routine.
    ///
    /// From here it is theirs — rename it, change the sets, delete it. There
    /// is no second kind of routine to maintain and nothing about it stays
    /// special after the tap.
    @discardableResult
    static func insert(_ split: StarterSplit, into context: ModelContext) -> Routine {
        let routine = Routine(name: split.name, folder: split.folder)
        context.insert(routine)

        for (index, exercise) in split.exercises.enumerated() {
            let entry = RoutineExercise(
                name: exercise.name,
                equipment: exercise.equipment,
                orderIndex: index
            )
            entry.routine = routine
            context.insert(entry)

            // One object per prescribed set. A routine's sets are targets, not
            // history: starting it creates the real day, and the routine is
            // never mutated by training against it.
            entry.prescribedSets = (0..<max(exercise.sets, 1)).map { setIndex in
                let set = RoutinePrescribedSet(
                    orderIndex: setIndex,
                    targetReps: exercise.reps,
                    targetDurationSec: exercise.durationSec
                )
                context.insert(set)
                return set
            }
        }

        try? context.save()
        return routine
    }
}
