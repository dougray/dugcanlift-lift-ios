import Foundation
import LiftCore

/// What is left of today's goal: the "kcal left" Home shows, and what Road
/// Food ranks against. One place, so the two can never disagree -- LIFT web
/// made the same move (`remainingFor(day)` in `lift/app.js`, used by Home,
/// Food and Road Food).
///
/// Negative when the day is over its goal. Nil when no goal is set: the
/// placeholder numbers in `MacroGoals` are not a goal anyone chose, and
/// ranking against them would pretend otherwise.
struct RemainingMacros: Equatable {
    /// Goal minus eaten. Negative once the day is over.
    let calories: Double
    /// Protein goal minus protein eaten. Negative once it is met and passed.
    let proteinG: Double

    init(calories: Double, proteinG: Double) {
        self.calories = calories
        self.proteinG = proteinG
    }

    /// Nil unless the person saved a goal.
    static func forDay(goalIsSet: Bool, goalCalories: Double, goalProteinG: Double,
                       eaten: NutritionFacts) -> RemainingMacros? {
        guard goalIsSet, goalCalories.isFinite else { return nil }
        return RemainingMacros(calories: goalCalories - eaten.calories,
                               proteinG: goalProteinG - eaten.proteinG)
    }

    /// Whole calories as the screen says them. Truncated toward zero, which
    /// is what Home has always shown ("640 kcal left" for 640.7).
    var wholeCalories: Int { Int(calories.isFinite ? calories : 0) }

    /// Whole grams of protein as the screen says them, truncated like calories.
    var wholeProteinG: Int { Int(proteinG.isFinite ? proteinG : 0) }

    /// "640 kcal left" / "150 kcal over". Home's headline, word for word as
    /// Home computed it before this type existed: exactly on goal reads
    /// "0 kcal over".
    var calorieHeadline: String {
        calories > 0 ? "\(abs(wholeCalories)) kcal left" : "\(abs(wholeCalories)) kcal over"
    }
}
