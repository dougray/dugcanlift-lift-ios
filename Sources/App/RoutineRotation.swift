import Foundation
import SwiftData
import LiftCore

/// A folder of routines is a rotation: Push, Pull, Legs, Push… The routine up
/// next is the one after the last one started from that folder, wrapping
/// round, and the first of them before any has been started.
///
/// A folder's order is the order its routines were added in, names breaking
/// a tie. The default folder
/// ("Routines") is not a rotation: it is where routines go when nobody chose a
/// folder, so it groups nothing on purpose.
///
/// A day comes from a routine when it holds one of that routine's exercises,
/// by the `routine:<exercise id>` ref that `Routine.startSession` writes. A
/// routine that has been edited since keeps its exercises' ids, so its old
/// days still count; an exercise added later has a new id and simply has no
/// history yet.
///
/// Value inputs rather than `@Model`s, so the rule is tested without a store.
enum RoutineRotation {
    struct Member: Equatable {
        let id: UUID
        let createdAt: Date
        let name: String
        let exerciseIDs: Set<UUID>
    }

    struct Day: Equatable {
        let date: Date
        let exerciseRefIDs: Set<String>
    }

    struct UpNext: Equatable {
        let routineID: UUID
        /// The routine the rotation last moved through, nil before the first.
        let after: UUID?
        let lastDate: Date?
    }

    static func refID(_ exerciseID: UUID) -> String { "routine:\(exerciseID.uuidString)" }

    static func ordered(_ members: [Member]) -> [Member] {
        members.sorted {
            $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Nil for a folder of one, or the default folder.
    static func upNext(folder: String, members: [Member], days: [Day]) -> UpNext? {
        guard !folder.trimmingCharacters(in: .whitespaces).isEmpty, members.count >= 2 else {
            return nil
        }
        let order = ordered(members)
        let refs = order.map { Set($0.exerciseIDs.map(refID)) }

        for day in days.sorted(by: { $0.date > $1.date }) {
            // Two of a folder's routines started on one day: the later one in
            // the rotation is where it got to.
            guard let index = refs.indices.last(where: { !refs[$0].isDisjoint(with: day.exerciseRefIDs) })
            else { continue }
            return UpNext(routineID: order[(index + 1) % order.count].id,
                          after: order[index].id, lastDate: day.date)
        }
        return UpNext(routineID: order[0].id, after: nil, lastDate: nil)
    }

    /// Of every folder's up next, the one whose rotation was trained most
    /// recently: that is the programme someone is actually running. Nil when
    /// no folder's rotation has been started at all, because the first
    /// routine of every folder is not a suggestion anybody asked for.
    static func current(_ folders: [(folder: String, members: [Member])],
                        days: [Day]) -> (folder: String, upNext: UpNext)? {
        folders
            .compactMap { group in
                upNext(folder: group.folder, members: group.members, days: days)
                    .map { (folder: group.folder, upNext: $0) }
            }
            .filter { $0.upNext.lastDate != nil }
            .max { $0.upNext.lastDate! < $1.upNext.lastDate! }
    }
}

// MARK: - From the store

extension RoutineRotation {
    static func folders(_ routines: [Routine]) -> [(folder: String, members: [Member])] {
        Dictionary(grouping: routines, by: \.folder).map { folder, routines in
            (folder: folder, members: routines.map(member))
        }
    }

    static func member(_ routine: Routine) -> Member {
        Member(id: routine.id, createdAt: routine.createdAt, name: routine.name,
               exerciseIDs: Set(routine.orderedExercises.map(\.id)))
    }

    static func day(_ day: WorkoutDay) -> Day {
        Day(date: day.date, exerciseRefIDs: Set(day.exercises.map(\.exerciseRefID)))
    }

    /// How far back the store is read: plenty for any rotation someone is
    /// running, without reading years of history on every redraw.
    static var recentDays: FetchDescriptor<WorkoutDay> {
        var descriptor = FetchDescriptor<WorkoutDay>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 120
        return descriptor
    }
}
