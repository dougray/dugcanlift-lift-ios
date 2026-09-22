import Foundation
import LiftSync

// Formatting for the plan the phone pushes, kept in LiftKit rather than
// beside the wire types in LiftSync: it needs the watch's own `WeightUnit`,
// and the phone never renders a plan this way. It lives beside the rules it
// formats rather than in a view: "blank must never render as zero" is the
// whole point of these types, and a rule in a view's body cannot be tested.

extension WorkoutPlan.Source {
    public var displayName: String {
        switch self {
        case .routine:   return "Routine"
        case .coachPlan: return "From your coach"
        }
    }
}

extension PlanExercise {
    /// "Deadlift (Barbell)" — the same convention `DraftExercise` uses.
    public var displayName: String {
        guard let equipment, !equipment.isEmpty else { return name }
        return "\(name) (\(equipment.capitalized))"
    }
}

extension PrescribedSet {

    /// The weight alone — "185" — or `nil` when none is prescribed. Rounded
    /// the way a plate-loaded bar actually goes: whole numbers stay whole.
    public func weightText(unit: WeightUnit) -> String? {
        guard let weightKg else { return nil }
        return PlanFormat.weight(weightKg, unit: unit)
    }

    /// The big line on the Now screen: "185 x 5", "5 reps", "185 lb", or
    /// "—" when this set prescribes nothing at all. Never "0 x 5".
    public func headline(unit: WeightUnit) -> String {
        switch (weightText(unit: unit), reps) {
        case let (weight?, reps?): return "\(weight) x \(reps)"
        case let (weight?, nil):   return "\(weight) \(unit.abbreviation)"
        case let (nil, reps?):     return "\(reps) reps"
        case (nil, nil):           return "—"
        }
    }

    /// Everything the set prescribes, RPE included: "185 x 5 @8".
    public func summary(unit: WeightUnit) -> String {
        var text = headline(unit: unit)
        if let rpe { text += " @\(PlanFormat.rpe(rpe))" }
        return text
    }
}

extension LastPerformed {
    /// "185x5 @8" — the reference line under the prescription. `nil` when the
    /// record holds no numbers worth showing, so the caller shows nothing at
    /// all rather than a dash pretending to be history.
    public func summary(unit: WeightUnit) -> String? {
        var text = ""
        if let weightKg, let reps {
            text = "\(PlanFormat.weight(weightKg, unit: unit))x\(reps)"
        } else if let weightKg {
            text = "\(PlanFormat.weight(weightKg, unit: unit)) \(unit.abbreviation)"
        } else if let reps {
            text = "\(reps) reps"
        } else {
            return nil
        }
        if let rpe { text += " @\(PlanFormat.rpe(rpe))" }
        return text
    }
}

public enum PlanFormat {
    /// Trailing ".0" is noise on a wrist; a real half-kilo is not.
    public static func weight(_ kilograms: Double, unit: WeightUnit) -> String {
        let value = unit.fromKilograms(kilograms)
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
    }

    public static func rpe(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
