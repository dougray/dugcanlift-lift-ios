import Foundation
import LiftCore

/// Editing a food entry that is already in the log: the amount, the meal, and
/// for a food with no reference behind it, its name and macros.
///
/// A value type with no view in it, for the reason `RecipeMacroEntry` is one: a
/// rule living in a view's `@State` cannot be tested, and this one decides what
/// lands in a day's total.
///
/// **Amount.** An entry is edited in whichever terms it was logged in. One with
/// `amountGrams` came through the gram-based flow, so the amount is shown and
/// typed in the person's `ServingUnit` and converted to grams exactly as
/// `FoodSearchView.log` does. One without is a count of servings (a legacy
/// entry, a recipe logged by servings, or a restore from another platform).
/// `FoodEntry.nutrition` is already scaled to the logged amount, and both ways
/// of computing it on log are linear in that amount — `FoodRecord.nutrition(grams:)`
/// is per-100 g times grams, `PlannedMeal.scaledNutrition` per-gram or
/// per-serving times the amount — so a new amount scales every stored value by
/// new ÷ old. That includes saturated fat, sugar and sodium, and it keeps a nil
/// nil: a food whose source never recorded sodium has none to scale.
///
/// **Macros.** Only editable for a *manual* entry — one whose `foodRefID` is
/// empty, which is what a restore from LIFT web or Android produces, since
/// those files carry no reference id. A food from the database or a recipe has
/// a source its numbers came from; letting them drift from it would make the
/// snapshot a lie about where it came from. The fields always show the totals
/// for the amount currently typed. Typing a value fixes all eight at that
/// amount; changing the amount afterwards scales them from there. Only the four
/// macros `NutritionFacts` cannot hold as nil are required. Fibre, and the three
/// under "More nutrients" (saturated fat, sugar, sodium), left blank stay nil
/// rather than becoming a measured zero — they are tracked, never targeted, and
/// an unknown is not a zero.
///
/// **Numbers.** Written with a `.` decimal, and read back accepting `.` or `,`,
/// because the decimal pad types a comma in many locales. Formatter and parser
/// live together here so they cannot be mismatched.
struct FoodEntryEdit: Equatable {

    enum Macro: String, CaseIterable, Identifiable {
        case calories, protein, carbs, fat, fiber
        case saturatedFat, sugar, sodium

        var id: String { rawValue }

        var label: String {
            switch self {
            case .calories:     return "Calories"
            case .protein:      return "Protein"
            case .carbs:        return "Carbs"
            case .fat:          return "Fat"
            case .fiber:        return "Fibre"
            case .saturatedFat: return "Saturated fat"
            case .sugar:        return "Sugar"
            case .sodium:       return "Sodium"
            }
        }

        var unit: String {
            switch self {
            case .calories: return "kcal"
            case .sodium:   return "mg"
            default:        return "g"
            }
        }

        /// The four `NutritionFacts` cannot leave unknown.
        var isRequired: Bool { [.calories, .protein, .carbs, .fat].contains(self) }

        /// Saturated fat, sugar and sodium: shown under "More nutrients", with
        /// no goal anywhere in the app.
        var isDetail: Bool { [.saturatedFat, .sugar, .sodium].contains(self) }
    }

    enum AmountMode: Equatable {
        /// Typed in this unit, stored as grams.
        case weight(ServingUnit)
        /// A count, labelled with the entry's own unit ("serving", "slice").
        case servings
    }

    /// What `apply(to:)` writes. Separate from the entry so it can be checked
    /// without a model container.
    struct Result: Equatable {
        var name: String
        var mealType: MealType
        var quantity: Double
        var servingUnit: String
        var amountGrams: Double?
        var nutrition: NutritionFacts
    }

    let mode: AmountMode
    let isManual: Bool

    var name: String
    var mealType: MealType

    /// Clearing the typed macros on every change is what makes "typing fixes
    /// the macros at this amount" hold: a raw string survives only while the
    /// amount it was typed against is still the amount on screen.
    var amountText: String {
        didSet { if amountText != oldValue { typedText = [:] } }
    }

    // The entry as it was, so an untouched amount changes nothing at all.
    private let originalAmount: Double
    private let originalAmountText: String
    private let originalQuantity: Double
    private let originalServingUnit: String
    private let originalAmountGrams: Double?
    private let originalName: String

    /// Values that hold at `baseAmount`. A missing key is a blank.
    private var base: [Macro: Double]
    /// Grams or servings, per `mode`.
    private var baseAmount: Double
    private var typedText: [Macro: String] = [:]

    init(entry: FoodEntry, preferredUnit: ServingUnit) {
        self.init(
            name: entry.name,
            foodRefID: entry.foodRefID,
            mealType: entry.mealType,
            quantity: entry.quantity,
            servingUnit: entry.servingUnit,
            amountGrams: entry.amountGrams,
            nutrition: entry.nutrition,
            preferredUnit: preferredUnit
        )
    }

    init(name: String, foodRefID: String, mealType: MealType,
         quantity: Double, servingUnit: String, amountGrams: Double?,
         nutrition: NutritionFacts, preferredUnit: ServingUnit) {
        self.name = name
        self.originalName = name
        self.mealType = mealType
        self.isManual = foodRefID.trimmingCharacters(in: .whitespaces).isEmpty

        if let amountGrams {
            mode = .weight(preferredUnit)
            originalAmount = amountGrams
            originalAmountText = Self.format(preferredUnit.fromGrams(amountGrams))
        } else {
            mode = .servings
            originalAmount = quantity
            originalAmountText = Self.format(quantity)
        }
        amountText = originalAmountText
        baseAmount = originalAmount
        originalQuantity = quantity
        originalServingUnit = servingUnit
        originalAmountGrams = amountGrams

        var macros: [Macro: Double] = [
            .calories: nutrition.calories,
            .protein: nutrition.proteinG,
            .carbs: nutrition.carbsG,
            .fat: nutrition.fatG
        ]
        macros[.fiber] = nutrition.fiberG
        macros[.saturatedFat] = nutrition.saturatedFatG
        macros[.sugar] = nutrition.sugarG
        macros[.sodium] = nutrition.sodiumMg
        base = macros
    }

    // MARK: - Amount

    /// Can the amount change at all? An entry logged as zero of something has
    /// no per-unit value to scale from, so its amount is left as it is.
    var canChangeAmount: Bool { originalAmount.isFinite && originalAmount > 0 }

    var amountUnitLabel: String {
        switch mode {
        case .weight(let unit): return unit.abbreviation
        case .servings:
            // "serving" / "servings" follows the count; any other unit is the
            // entry's own and is left alone.
            if Self.isServingWord(originalServingUnit) {
                return (amount(inDisplayUnits: true) ?? originalQuantity) == 1 ? "serving" : "servings"
            }
            return originalServingUnit
        }
    }

    /// The amount in grams (weight mode) or servings, or nil when what is typed
    /// is not a positive number.
    var amount: Double? { amount(inDisplayUnits: false) }

    private func amount(inDisplayUnits: Bool) -> Double? {
        guard canChangeAmount else { return originalAmount }
        if amountText == originalAmountText {
            // Exactly the stored value, not the rounded text: 4.9 oz displayed
            // must not rescale a 140 g entry to 138.9 g on an untouched save.
            if inDisplayUnits, case .weight(let unit) = mode { return unit.fromGrams(originalAmount) }
            return originalAmount
        }
        guard let typed = Self.parse(amountText), typed > 0 else { return nil }
        if !inDisplayUnits, case .weight(let unit) = mode { return unit.toGrams(typed) }
        return typed
    }

    private var ratio: Double? {
        guard canChangeAmount else { return 1 }
        guard let amount else { return nil }
        return amount / baseAmount
    }

    // MARK: - Macros

    /// The macro fields are editable only for a manual entry, and only while
    /// the amount is a real number — there is nothing to hold them against
    /// otherwise.
    var canEditMacros: Bool { isManual && amount != nil }

    /// What the field shows: the text as typed, or the total at this amount.
    func text(for macro: Macro) -> String {
        if let typed = typedText[macro] { return typed }
        guard let value = base[macro] else { return "" }
        return Self.format(value * (ratio ?? 1))
    }

    mutating func setText(_ text: String, for macro: Macro) {
        guard canEditMacros, let amount, let ratio else { return }
        if ratio != 1 {
            // Re-base every value at the amount on screen, so what is typed and
            // what is not are totals for the same amount.
            base = base.mapValues { $0 * ratio }
            baseAmount = amount
        }
        typedText[macro] = text
        // A negative macro is not a number anyone means; it counts as blank.
        base[macro] = Self.parse(text).flatMap { $0 >= 0 ? $0 : nil }
    }

    /// Nutrition at the amount on screen. nil when a required macro is blank.
    var nutrition: NutritionFacts? {
        let r = ratio ?? 1
        guard let calories = base[.calories], let protein = base[.protein],
              let carbs = base[.carbs], let fat = base[.fat] else { return nil }
        return NutritionFacts(
            calories: calories * r,
            proteinG: protein * r,
            carbsG: carbs * r,
            fatG: fat * r,
            fiberG: base[.fiber].map { $0 * r },
            sugarG: base[.sugar].map { $0 * r },
            sodiumMg: base[.sodium].map { $0 * r },
            saturatedFatG: base[.saturatedFat].map { $0 * r }
        )
    }

    // MARK: - Saving

    /// What the reason is, in words, when Save is not available.
    var problem: String? {
        if isManual && name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the food a name." }
        if amount == nil { return "Enter an amount above zero." }
        if nutrition == nil {
            let blank = Macro.allCases.filter { $0.isRequired && base[$0] == nil }.map { $0.label.lowercased() }
            return "Enter \(ListFormatter.localizedString(byJoining: blank)). Everything else can be left blank."
        }
        return nil
    }

    var result: Result? {
        guard problem == nil, let amount, let nutrition else { return nil }
        var out = Result(
            name: isManual ? name.trimmingCharacters(in: .whitespaces) : originalName,
            mealType: mealType,
            quantity: originalQuantity,
            servingUnit: originalServingUnit,
            amountGrams: originalAmountGrams,
            nutrition: nutrition
        )
        if amountText != originalAmountText && canChangeAmount {
            switch mode {
            case .weight(let unit):
                // As FoodSearchView.log writes it: the typed figure and its
                // unit, with grams as the authority.
                out.amountGrams = amount
                out.quantity = Self.parse(amountText) ?? unit.fromGrams(amount)
                out.servingUnit = unit.abbreviation
            case .servings:
                out.quantity = amount
                if Self.isServingWord(originalServingUnit) {
                    out.servingUnit = amount == 1 ? "serving" : "servings"
                }
            }
        }
        return out
    }

    /// Writes the edit onto the entry in place. Its id, `loggedAt` and `dayKey`
    /// are not touched: moving a food to another meal keeps it on the same day
    /// and in the same place in that day's order. `healthKitUUID` is not touched
    /// either — see `FoodEntryEditorView` for why.
    @discardableResult
    func apply(to entry: FoodEntry) -> Bool {
        guard let result else { return false }
        entry.name = result.name
        entry.mealType = result.mealType
        entry.quantity = result.quantity
        entry.servingUnit = result.servingUnit
        entry.amountGrams = result.amountGrams
        entry.nutrition = result.nutrition
        return true
    }

    // MARK: - Numbers

    private static func isServingWord(_ unit: String) -> Bool {
        let lower = unit.lowercased()
        return lower == "serving" || lower == "servings"
    }

    /// "150", "4.9", "0.3". One decimal is as fine as a person weighs food.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rounded)
    }

    /// Reads what `format` writes, and a comma decimal. Blank is nil, never 0.
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }
}
