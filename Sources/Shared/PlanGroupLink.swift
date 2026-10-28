import Foundation
import LiftCore

/// `g` in a coach's plan link: the group each exercise of each workout is done
/// in (PLAN-FORMAT.md "Set types").
///
/// **Read here, not by `PlanLinkCodec`**, for the reason `rf` is
/// (`RoadPickLink`): `PlanWorkoutExercise` is LiftKit's, the kit is pinned to
/// an exact tag Coach iOS shares, and one optional integer on an exercise is
/// not worth a kit release plus a bump in two shipped apps. Coach iOS writes it
/// the mirror way (`PayloadWithAppKeys`), and Coach web's fixture
/// `web-plan-set-types.txt` is the contract between them.
///
/// The kind half of set types needs no reader of this sort: it is bits 3-4 of
/// the set tuple's sixth position, which `PlanPayload` already decodes as a
/// number, and `SetKind(planTuple:)` masks it.
///
/// **Lenient, and never throws**, like `RoadPickLink`: by the time this is
/// asked, `PlanLinkCodec.decode` has accepted the fragment, and a `g` that is
/// junk is *not grouped*, never a plan that will not open.
///
/// In its own file, with no SwiftData in it, because the share extension
/// compiles it beside `PlanLinkIntake`.
enum PlanGroupLink {

    /// Each workout's `g` values, exercise by exercise, as sent: a positive
    /// integer or nil. Adjacency is not applied here -- `ExerciseGrouping.runs`
    /// does that where the groups are stored. Empty when no exercise anywhere
    /// carries a group, which is every plan written before set types.
    static func groups(inFragment fragment: String) -> [[Int?]] {
        RoadPickLink.payloadJSON(inFragment: fragment).map(groups(inJSON:)) ?? []
    }

    static func groups(inJSON json: Data) -> [[Int?]] {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let workouts = object["w"] as? [Any] else { return [] }
        let groups: [[Int?]] = workouts.map { workout in
            guard let exercises = (workout as? [String: Any])?["e"] as? [Any] else { return [] }
            return exercises.map { groupOf(json: ($0 as? [String: Any])?["g"]) }
        }
        return groups.contains { $0.contains { $0 != nil } } ? groups : []
    }

    /// A `g` as `JSONSerialization` hands it over. Only a JSON number that is a
    /// positive integer is a group: a string, a fraction, a negative, zero, a
    /// boolean, `null` or anything else is not grouped.
    static func groupOf(json value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, double > 0, double < 1_000_000 else { return nil }
        return Int(double)
    }
}
