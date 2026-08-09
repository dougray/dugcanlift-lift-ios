import Foundation
import SwiftData

enum MealType: String, Codable, CaseIterable, Identifiable {
    case breakfast, lunch, dinner, snack

    var id: String { rawValue }

    var displayName: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    /// Used for ordering a day's entries in the log view.
    var sortOrder: Int {
        switch self {
        case .breakfast: 0
        case .lunch:     1
        case .dinner:    2
        case .snack:     3
        }
    }
}

/// Macros for one logged portion, as consumed — not per 100 g.
///
/// SwiftData stores this inline as a Codable value, so there is no relationship
/// to traverse and no extra fetch when summing a day.
struct NutritionFacts: Codable, Hashable, Sendable {
    var calories: Double = 0
    var proteinG: Double = 0
    var carbsG: Double = 0
    var fatG: Double = 0
    var fiberG: Double?
    var sugarG: Double?
    var sodiumMg: Double?

    static let zero = NutritionFacts()

    static func + (lhs: NutritionFacts, rhs: NutritionFacts) -> NutritionFacts {
        NutritionFacts(
            calories: lhs.calories + rhs.calories,
            proteinG: lhs.proteinG + rhs.proteinG,
            carbsG:   lhs.carbsG + rhs.carbsG,
            fatG:     lhs.fatG + rhs.fatG,
            fiberG:   optionalSum(lhs.fiberG, rhs.fiberG),
            sugarG:   optionalSum(lhs.sugarG, rhs.sugarG),
            sodiumMg: optionalSum(lhs.sodiumMg, rhs.sodiumMg)
        )
    }

    /// nil + nil stays nil, so "no fibre data" never silently becomes "0 g".
    private static func optionalSum(_ a: Double?, _ b: Double?) -> Double? {
        guard a != nil || b != nil else { return nil }
        return (a ?? 0) + (b ?? 0)
    }

    func scaled(by factor: Double) -> NutritionFacts {
        NutritionFacts(
            calories: calories * factor,
            proteinG: proteinG * factor,
            carbsG:   carbsG * factor,
            fatG:     fatG * factor,
            fiberG:   fiberG.map { $0 * factor },
            sugarG:   sugarG.map { $0 * factor },
            sodiumMg: sodiumMg.map { $0 * factor }
        )
    }
}

@Model
final class FoodEntry {
    var id: UUID = UUID()
    var loggedAt: Date = Date.now
    var dayKey: String = ""

    private var mealTypeRaw: String = MealType.snack.rawValue
    var mealType: MealType {
        get { MealType(rawValue: mealTypeRaw) ?? .snack }
        set { mealTypeRaw = newValue.rawValue }
    }

    /// Namespaced foreign key, e.g. "usda:174608" or "off:3017620422003".
    var foodRefID: String = ""

    // Snapshot fields — see the note in ExerciseEntry. Open Food Facts in
    // particular is crowd-edited and changes constantly; a meal logged in
    // January must still show what it showed in January.
    var name: String = ""
    var brand: String?

    var quantity: Double = 1
    var servingUnit: String = "serving"
    var servingGrams: Double?

    /// Already scaled to `quantity`. Summing a day is a plain reduce.
    var nutrition: NutritionFacts = NutritionFacts.zero

    var healthKitUUID: UUID?

    init(foodRefID: String, name: String, brand: String? = nil,
         quantity: Double, servingUnit: String, servingGrams: Double? = nil,
         nutrition: NutritionFacts, mealType: MealType, loggedAt: Date = .now) {
        self.id = UUID()
        self.foodRefID = foodRefID
        self.name = name
        self.brand = brand
        self.quantity = quantity
        self.servingUnit = servingUnit
        self.servingGrams = servingGrams
        self.nutrition = nutrition
        self.mealTypeRaw = mealType.rawValue
        self.loggedAt = loggedAt
        self.dayKey = DayKey.make(from: loggedAt)
    }

    var displayName: String {
        guard let brand, !brand.isEmpty else { return name }
        return "\(brand) \(name)"
    }
}

extension Array where Element == FoodEntry {
    var totalNutrition: NutritionFacts {
        reduce(.zero) { $0 + $1.nutrition }
    }

    func grouped() -> [(meal: MealType, entries: [FoodEntry])] {
        Dictionary(grouping: self, by: \.mealType)
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { (meal: $0.key, entries: $0.value.sorted { $0.loggedAt < $1.loggedAt }) }
    }
}

/// Fetch descriptors used by both the app and the widget.
enum LiftQueries {
    static func foodEntries(on dayKey: String) -> FetchDescriptor<FoodEntry> {
        FetchDescriptor<FoodEntry>(
            predicate: #Predicate { $0.dayKey == dayKey },
            sortBy: [SortDescriptor(\.loggedAt)]
        )
    }

    static func workouts(on dayKey: String) -> FetchDescriptor<WorkoutSession> {
        FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.dayKey == dayKey },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
    }

    static func activeWorkout() -> FetchDescriptor<WorkoutSession> {
        var descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.endedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return descriptor
    }
}
