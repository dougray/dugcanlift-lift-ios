import Foundation
import SwiftData

/// COOK — recipes, meal planning and the shopping list derived from them.
///
/// COOK is to eating what COACH is to training: a named surface that spans an
/// in-app section, a page on the site, and one written contract every client
/// shares. See `CoachShare.swift` for the pattern.
///
/// Lives in `Shared/` so the widget extension can render "tonight's dinner"
/// from a `PlannedMeal`. That is why this file imports only Foundation and
/// SwiftData — no GRDB. Resolving an ingredient to macros needs the bundled
/// reference database and therefore belongs in `Sources/Reference/`, app
/// target only.
///
/// The wire format these models are populated from is defined once and shared
/// with the Android app and the public library, the same way
/// `coach/SHARE-FORMAT.md` is shared. It currently lives at
/// `homelab/cook-ingest/schema/recipe.schema.json` and belongs in
/// `dugcanlift-site/cook/` next to COACH's. Nutrition on the wire is always
/// PER SERVING.

// MARK: - Recipe

@Model
final class Recipe {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date.now

    /// The post this came from. nil for a hand-entered recipe.
    var sourceURL: URL?
    var sourceAuthor: String?

    var servings: Double = 1
    var prepMinutes: Int?
    var cookMinutes: Int?

    var steps: [String] = []

    /// Per serving, and deliberately optional. An LLM guess at the macros of a
    /// hand-written recipe is a guess; `nil` says so, whereas `.zero` would
    /// quietly enter a day's total as fact.
    var nutritionPerServing: NutritionFacts?

    /// True when the macros above were estimated rather than resolved against a
    /// food database. Surfaced in the UI before the user logs anything.
    var nutritionIsEstimated: Bool = false

    /// Total finished weight of the whole dish, in grams. `nil` until Doug
    /// (or any user) fills it in via the recipe editor — neither platform
    /// tracked this before, and per-ingredient gram resolution is too
    /// unreliable to infer it automatically (see `IngredientParser.parse`'s
    /// own doc comment: only ingredients already written in grams resolve).
    /// A recipe with `totalWeightGrams == nil` keeps working exactly as
    /// before — servings-based planning/logging via `PlannedMeal.servings`.
    var totalWeightGrams: Double?

    /// Caption, transcript and OCR text merged, kept verbatim.
    ///
    /// This is not a nicety. An import is shown next to its source text so a
    /// misheard quantity is visible before it is saved. Never auto-log an
    /// imported recipe, and never drop this to save space.
    var sourceTranscript: String?

    @Relationship(deleteRule: .cascade, inverse: \RecipeIngredient.recipe)
    var ingredients: [RecipeIngredient]? = []

    init(name: String,
         servings: Double = 1,
         steps: [String] = [],
         sourceURL: URL? = nil,
         sourceAuthor: String? = nil,
         nutritionPerServing: NutritionFacts? = nil,
         nutritionIsEstimated: Bool = false,
         sourceTranscript: String? = nil,
         createdAt: Date = .now) {
        self.id = UUID()
        self.name = name
        self.servings = max(servings, 0.0001)
        self.steps = steps
        self.sourceURL = sourceURL
        self.sourceAuthor = sourceAuthor
        self.nutritionPerServing = nutritionPerServing
        self.nutritionIsEstimated = nutritionIsEstimated
        self.sourceTranscript = sourceTranscript
        self.createdAt = createdAt
        self.ingredients = []
    }

    /// Namespaced the same way as `usda:` and `off:` on `FoodEntry.foodRefID`.
    var foodRefID: String { "recipe:\(id.uuidString)" }

    var wasImported: Bool { sourceURL != nil }

    /// Total nutrition for the whole finished dish — `nutritionPerServing`
    /// (per ONE serving) times how many servings the recipe yields. `nil`
    /// if `nutritionPerServing` was never entered/estimated.
    var totalNutrition: NutritionFacts? {
        nutritionPerServing?.scaled(by: servings)
    }

    /// Nutrition per gram of the finished dish. `nil` until both
    /// `nutritionPerServing` and `totalWeightGrams` exist.
    var nutritionPerGram: NutritionFacts? {
        guard let totalNutrition, let totalWeightGrams, totalWeightGrams > 0
        else { return nil }
        return totalNutrition.scaled(by: 1 / totalWeightGrams)
    }
}

// MARK: - Ingredient

@Model
final class RecipeIngredient {
    var id: UUID = UUID()

    /// Exactly as heard or read — "2 tbsp olive oil".
    ///
    /// Always populated, even when the parse below succeeded. It is what the
    /// user checks the parse against, and what the shopping list falls back to
    /// when `qty` and `unit` could not be resolved.
    var rawText: String = ""

    /// Normalised name — "olive oil". nil when parsing failed.
    var item: String?
    var qty: Double?
    var unit: String?

    /// Resolved mass, when a conversion was possible. Drives macro lookup.
    var grams: Double?

    /// Set once an ingredient has been matched to the reference database, so a
    /// recipe's macros can be computed. Same namespacing as `FoodEntry`.
    var foodRefID: String?

    var isOptional: Bool = false
    var note: String?
    var sortOrder: Int = 0

    var recipe: Recipe?

    init(rawText: String,
         item: String? = nil,
         qty: Double? = nil,
         unit: String? = nil,
         grams: Double? = nil,
         foodRefID: String? = nil,
         isOptional: Bool = false,
         note: String? = nil,
         sortOrder: Int = 0) {
        self.id = UUID()
        self.rawText = rawText
        self.item = item
        self.qty = qty
        self.unit = unit
        self.grams = grams
        self.foodRefID = foodRefID
        self.isOptional = isOptional
        self.note = note
        self.sortOrder = sortOrder
    }

    /// What to show in a list: the parse when it worked, the raw text when it
    /// did not.
    var displayText: String {
        guard let item, !item.isEmpty else { return rawText }
        let amount = [qty.map(Self.trimmed), unit]
            .compactMap { $0 }
            .joined(separator: " ")
        return amount.isEmpty ? item : "\(amount) \(item)"
    }

    private static func trimmed(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%g", value)
    }
}

// MARK: - Meal plan

/// A recipe placed on a future day. Not a log entry — nothing is eaten yet.
///
/// Logging one writes a separate `FoodEntry` that snapshots the numbers, the
/// same way `FoodEntry` already snapshots reference data. Editing a recipe in
/// March must not rewrite what January's log says was eaten.
@Model
final class PlannedMeal {
    var id: UUID = UUID()

    /// Set together with `plannedFor`, never independently — day-scoped
    /// queries use this key, not a date-range predicate.
    var dayKey: String = ""
    var plannedFor: Date = Date.now

    private var mealTypeRaw: String = MealType.dinner.rawValue
    var mealType: MealType {
        get { MealType(rawValue: mealTypeRaw) ?? .dinner }
        set { mealTypeRaw = newValue.rawValue }
    }

    var recipeID: UUID = UUID()

    /// How many servings of the recipe this meal is.
    var servings: Double = 1

    // Snapshot fields. The widget extension cannot open SQLite and cannot
    // traverse a relationship cheaply, so everything needed to render a
    // "tonight's dinner" tile is copied here at plan time.
    var recipeName: String = ""

    /// **Per serving, never pre-scaled by `servings`.**
    ///
    /// This is the invariant the wire format is built on and the Android build
    /// already follows. Storing it scaled works right up until a plan travels
    /// between clients, at which point one side is wrong by a factor of
    /// `servings` and nothing looks broken enough to notice.
    ///
    /// Multiply at the point of use: the UI for display, `makeFoodEntry()` for
    /// the log.
    var snapshotNutrition: NutritionFacts?

    /// Grams of the dish this planned/logged instance represents, when
    /// created via the gram-based recipe-logging flow. `nil` for legacy
    /// instances that use `servings` instead.
    var amountGrams: Double?

    /// `recipe.nutritionPerGram` captured once at creation time — matches
    /// `snapshotNutrition`'s own "snapshot on write" convention exactly, so
    /// a later edit to the recipe (a new totalWeightGrams, a corrected
    /// nutritionPerServing) never silently changes an already-planned or
    /// already-logged meal's numbers. `nil` whenever `amountGrams` is nil,
    /// or whenever the recipe had no `nutritionPerGram` at creation time.
    var snapshotNutritionPerGram: NutritionFacts?

    /// Set when this plan has been turned into an actual `FoodEntry`, so
    /// logging twice is visible and idempotent.
    var loggedFoodEntryID: UUID?

    init(recipe: Recipe, mealType: MealType, plannedFor: Date, servings: Double = 1, amountGrams: Double? = nil) {
        self.id = UUID()
        self.recipeID = recipe.id
        self.recipeName = recipe.name
        self.mealTypeRaw = mealType.rawValue
        self.plannedFor = plannedFor
        self.dayKey = DayKey.make(from: plannedFor)
        self.servings = servings
        self.snapshotNutrition = recipe.nutritionPerServing
        self.amountGrams = amountGrams
        self.snapshotNutritionPerGram = amountGrams != nil ? recipe.nutritionPerGram : nil
    }

    var isLogged: Bool { loggedFoodEntryID != nil }

    /// Prefers the gram-based snapshot when this instance was created via
    /// the gram-based flow; falls back to the legacy servings-based
    /// computation otherwise. Exactly one of the two snapshot fields is
    /// ever meaningfully non-nil for a given instance.
    var scaledNutrition: NutritionFacts? {
        if let amountGrams, let snapshotNutritionPerGram {
            return snapshotNutritionPerGram.scaled(by: amountGrams)
        }
        return snapshotNutrition?.scaled(by: servings)
    }

    /// Builds the log entry for this planned meal.
    ///
    /// `FoodEntry.nutrition` is already-scaled by contract, so the per-serving
    /// snapshot is multiplied here. Returns nil when the recipe never had
    /// macros — better no entry than a zero-calorie dinner in the day's total.
    func makeFoodEntry() -> FoodEntry? {
        guard let scaledNutrition else { return nil }
        if let amountGrams, snapshotNutritionPerGram != nil {
            return FoodEntry(
                foodRefID: "recipe:\(recipeID.uuidString)",
                name: recipeName,
                quantity: amountGrams,
                servingUnit: "g",
                amountGrams: amountGrams,
                nutrition: scaledNutrition,
                mealType: mealType,
                loggedAt: plannedFor
            )
        }
        return FoodEntry(
            foodRefID: "recipe:\(recipeID.uuidString)",
            name: recipeName,
            quantity: servings,
            servingUnit: servings == 1 ? "serving" : "servings",
            nutrition: scaledNutrition,
            mealType: mealType,
            loggedAt: plannedFor
        )
    }
}

// MARK: - Shopping list

/// The shopping list is derived from the planned meals in a date range, not
/// stored. Only the tick-off state is persisted, keyed by the normalised item
/// name, so re-deriving the list does not lose what is already in the basket.
@Model
final class ShoppingListCheck {
    var id: UUID = UUID()
    /// Lowercased, whitespace-trimmed item name.
    var itemKey: String = ""
    var checkedAt: Date = Date.now

    init(itemKey: String, checkedAt: Date = .now) {
        self.id = UUID()
        self.itemKey = itemKey
        self.checkedAt = checkedAt
    }
}

/// One aggregated line on the shopping list. A value type — never persisted.
struct ShoppingListLine: Identifiable, Hashable {
    var id: String { key }
    /// Lowercased item name, used to match `ShoppingListCheck`.
    let key: String
    let displayName: String
    /// Summed per unit. Quantities in units that cannot be combined stay apart,
    /// which is why this is a dictionary rather than a single total.
    let amounts: [String: Double]
    /// Raw strings for ingredients that never parsed. Shown as-is so nothing is
    /// silently dropped from the list.
    let unparsed: [String]

    var isCheckedKey: String { key }
}

enum ShoppingList {

    /// Aggregates the ingredients of the given planned meals.
    ///
    /// Amounts are scaled by each meal's servings relative to the recipe's own
    /// serving count, so planning two servings of a four-serving recipe buys
    /// half the ingredients.
    static func build(from meals: [PlannedMeal],
                      recipes: [UUID: Recipe]) -> [ShoppingListLine] {
        var amounts: [String: [String: Double]] = [:]
        var names: [String: String] = [:]
        var unparsed: [String: [String]] = [:]

        for meal in meals {
            guard let recipe = recipes[meal.recipeID] else { continue }
            let factor = meal.servings / max(recipe.servings, 0.0001)

            for ingredient in recipe.ingredients ?? [] where !ingredient.isOptional {
                let name = ingredient.item ?? ingredient.rawText
                let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                names[key] = names[key] ?? name

                if let qty = ingredient.qty, let unit = ingredient.unit {
                    amounts[key, default: [:]][unit, default: 0] += qty * factor
                } else {
                    unparsed[key, default: []].append(ingredient.rawText)
                }
            }
        }

        return names.keys.sorted().map { key in
            ShoppingListLine(
                key: key,
                displayName: names[key] ?? key,
                amounts: amounts[key] ?? [:],
                unparsed: unparsed[key] ?? []
            )
        }
    }
}
