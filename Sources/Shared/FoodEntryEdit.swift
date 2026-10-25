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
/// those files carry no reference id, or `barcode:<code>`, whose numbers the
/// person typed themselves. Correcting a `barcode:` entry changes that entry
/// only, never the food remembered against the code. A food from the database or a recipe has
/// a source its numbers came from; letting them drift from it would make the
/// snapshot a lie about where it came from. The fields always show the totals
/// for the amount currently typed. Typing a value fixes all eight at that
/// amount; changing the amount afterwards scales them from there. Only the four
/// macros `NutritionFacts` cannot hold as nil are required. Fibre, and the three
/// under "More nutrients" (saturated fat, sugar, sodium), left blank stay nil
/// rather than becoming a measured zero — they are tracked, never targeted, and
/// an unknown is not a zero.
///
/// **A new entry.** Food search's "Add food by hand" uses the same rules for a
/// food that is not in the log yet (`init(newNamed:mealType:preferredUnit:)`),
/// with one difference, LIFT web's: the macros are typed **per 100 g**, as a
/// label reads, and the amount eaten — 100 g to start, in the person's unit —
/// scales them, so the totals are per-100 g × grams ÷ 100. The fields stay per
/// 100 g whatever the amount, so changing it never rewrites what was typed.
/// Blank still stays blank and the same four are required: LIFT web's form
/// reads a blank protein, carbs or fat as 0, and this does not copy that.
/// `makeEntry()` builds what `FoodSearchView.log` would for a database food, with
/// `foodRefID` empty (or `barcode:<code>`, below) — which is what makes it
/// manual — and no brand. Reopened later it is an ordinary manual entry, edited as totals at its amount.
///
/// **A barcode.** A new entry may carry the barcode it was added against
/// (`barcode`, `Barcode.normalised`). Then `makeEntry()` writes
/// `foodRefID` `barcode:<code>` rather than empty, and `per100g` — the fields
/// exactly as typed, at no amount — is what the editor remembers against that
/// code, so the next scan finds the food as its label reads, not as one
/// serving of it.
///
/// **A remembered food** (`init(remembering:preferredUnit:)`): only what LIFT
/// remembers about a barcode, never a log entry. Its name and per-100 g
/// fields, prefilled, with an unknown left blank. No meal and no amount: the
/// amount is held at 100 g and never shown, so `problem` never asks for one,
/// and `makeEntry()` is always nil.
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
    /// Not in the log yet: macros typed per 100 g. See "A new entry" above.
    let isNew: Bool
    /// Editing what LIFT remembers about a barcode, not an entry. See "A
    /// remembered food" above.
    let editsRememberedFoodOnly: Bool
    /// The normalised code a new entry was added against. Read only by
    /// `makeEntry()`, which only a new entry makes, so it means nothing in the
    /// other modes.
    var barcode: String?

    /// The fields are per 100 g as typed, rather than totals at an amount.
    private var typesPer100g: Bool { isNew || editsRememberedFoodOnly }

    var name: String
    var mealType: MealType

    /// Clearing the typed macros on every change is what makes "typing fixes
    /// the macros at this amount" hold: a raw string survives only while the
    /// amount it was typed against is still the amount on screen. A new
    /// entry's fields are per 100 g, not totals, so its text is kept as typed.
    var amountText: String {
        didSet { if amountText != oldValue && !typesPer100g { typedText = [:] } }
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
        let ref = foodRefID.trimmingCharacters(in: .whitespaces)
        self.isManual = ref.isEmpty || ref.hasPrefix("barcode:")
        self.isNew = false
        self.editsRememberedFoodOnly = false

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

        base = Self.values(of: nutrition)
    }

    /// A food added by hand, not in the log yet: macros per 100 g, every one
    /// blank, and 100 g eaten in the person's unit. Left untouched, the amount
    /// is exactly 100 g rather than whatever its rounded text reads back as.
    init(newNamed name: String, mealType: MealType, preferredUnit: ServingUnit) {
        self.init(per100gNamed: name, mealType: mealType, preferredUnit: preferredUnit,
                  rememberedFoodOnly: false)
    }

    /// What LIFT remembers about a barcode: its name and per-100 g values,
    /// an unknown one blank. The meal is a placeholder nothing reads.
    init(remembering food: RememberedFood, preferredUnit: ServingUnit) {
        self.init(per100gNamed: food.name, mealType: .snack, preferredUnit: preferredUnit,
                  rememberedFoodOnly: true)
        base = Self.values(of: food.per100g)
    }

    private init(per100gNamed name: String, mealType: MealType, preferredUnit: ServingUnit,
                 rememberedFoodOnly: Bool) {
        self.name = name
        originalName = name
        self.mealType = mealType
        isManual = true
        isNew = !rememberedFoodOnly
        editsRememberedFoodOnly = rememberedFoodOnly
        mode = .weight(preferredUnit)
        originalAmount = 100
        originalAmountText = Self.format(preferredUnit.fromGrams(100))
        amountText = originalAmountText
        baseAmount = 100
        originalQuantity = preferredUnit.fromGrams(100)
        originalServingUnit = preferredUnit.abbreviation
        originalAmountGrams = 100
        base = [:]
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
    /// otherwise. A new entry's are per 100 g, which needs no amount.
    var canEditMacros: Bool { isManual && (typesPer100g || amount != nil) }

    /// The line under the macros card's title, in the terms its fields are in.
    var macrosHint: String {
        if isNew {
            return "As the label reads them per 100\u{00A0}g; the amount above works out the totals. Fibre can be left blank — blank stays unknown, not zero."
        }
        if editsRememberedFoodOnly {
            return "As the label reads them per 100\u{00A0}g. Fibre can be left blank — blank stays unknown, not zero."
        }
        if isManual { return "Totals for the amount above. Fibre can be left blank — blank stays unknown, not zero." }
        return "From the food's own data, scaled to the amount above."
    }

    /// The line over saturated fat, sugar and sodium, likewise.
    var detailsHint: String {
        if typesPer100g {
            return "Saturated fat, sugar and sodium, per 100\u{00A0}g like the macros. No goals — blank stays unknown, not zero."
        }
        if isManual {
            return "Saturated fat, sugar and sodium, as totals for the amount above. No goals — blank stays unknown, not zero."
        }
        return "From the food's own data, scaled to the amount above. No goals."
    }

    /// What the field shows: the text as typed, or the total at this amount —
    /// or, for a new entry, the value per 100 g.
    func text(for macro: Macro) -> String {
        if let typed = typedText[macro] { return typed }
        guard let value = base[macro] else { return "" }
        return Self.format(typesPer100g ? value : value * (ratio ?? 1))
    }

    /// The field's label: "Protein (g)", or for a new entry LIFT web's
    /// "Protein (g/100g)" and "Calories (per 100 g)".
    func fieldLabel(for macro: Macro) -> String {
        guard typesPer100g else { return "\(macro.label) (\(macro.unit))" }
        if macro == .calories { return "Calories (per 100 g)" }
        return "\(macro.label) (\(macro.unit)/100g)"
    }

    /// What VoiceOver says for a field, once and in words: "g/100g" read
    /// aloud is "g slash 100 g". The visible label is hidden from it.
    func spokenFieldLabel(for macro: Macro) -> String {
        let unit: String
        switch macro {
        case .calories: unit = "kilocalories"
        case .sodium:   unit = "milligrams"
        default:        unit = "grams"
        }
        guard typesPer100g else { return "\(macro.label), \(unit)" }
        if macro == .calories { return "Calories per 100 grams" }
        return "\(macro.label), \(unit) per 100 grams"
    }

    /// "Amount, grams", "Amount, ounces", or the entry's own count word.
    var spokenAmountLabel: String {
        switch mode {
        case .weight(let unit): return "Amount, \(unit == .grams ? "grams" : "ounces")"
        case .servings:         return "Amount, \(amountUnitLabel)"
        }
    }

    mutating func setText(_ text: String, for macro: Macro) {
        guard canEditMacros else { return }
        if !typesPer100g, let amount, let ratio, ratio != 1 {
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
    var nutrition: NutritionFacts? { facts(times: ratio ?? 1) }

    /// The fields as typed, per 100 g, whatever the amount: what is remembered
    /// against a barcode. nil when a required macro is blank, and for an entry
    /// already in the log, whose fields are totals rather than per 100 g.
    var per100g: NutritionFacts? {
        guard typesPer100g else { return nil }
        return facts(times: 1)
    }

    private func facts(times r: Double) -> NutritionFacts? {
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

    /// A new entry, as `FoodSearchView.log` makes one for a database food, with
    /// an empty `foodRefID` — or `barcode:<code>` when it carries one — and no
    /// brand. nil while something is missing, and
    /// always nil for an entry that is already in the log.
    func makeEntry(loggedAt: Date = .now) -> FoodEntry? {
        guard isNew, let result else { return nil }
        return FoodEntry(
            foodRefID: barcode.map { "barcode:" + $0 } ?? "",
            name: result.name,
            brand: nil,
            quantity: result.quantity,
            servingUnit: result.servingUnit,
            amountGrams: result.amountGrams,
            nutrition: result.nutrition,
            mealType: result.mealType,
            loggedAt: loggedAt
        )
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

    /// A `NutritionFacts` as field values: an unknown optional is a missing
    /// key, which the field shows blank.
    private static func values(of nutrition: NutritionFacts) -> [Macro: Double] {
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
        return macros
    }

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
