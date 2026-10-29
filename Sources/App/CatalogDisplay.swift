import Foundation
import LiftCore
import LiftReference

/// The bundled recipe catalogue's display rules, held outside
/// `RecipeCatalogView` because a rule in a view's `@State` cannot be tested.
///
/// Every LIFT and Coach build that ships the catalogue follows these three, so
/// a recipe reads the same on each:
///
/// 1. **With no search typed, the list is the whole catalogue, by name.** The
///    kit's `browseRecipes()` defaults to a first page of 60, which left most
///    of the 622 recipes findable only by searching. The kit attaches every
///    page's ingredients in one query, so the whole catalogue is two queries,
///    not one per row, and the list that shows it is lazy.
/// 2. **A whole-number macro is rounded, never truncated.** `Int(224.5)` is
///    224; LIFT Android, Coach Android and both web builds print 225. Rounding
///    is half away from zero, `Double.rounded()`'s default. Display only: what
///    is stored stays the raw quotient.
/// 3. **A recipe whose source states no yield asks for its servings**, with
///    macros or without. Without macros there is nothing to divide, but the
///    count is still saved with the recipe, and a count nobody chose is a
///    number they did not pick. The per-serving macro line shows only when
///    there are macros.
enum CatalogDisplay {

    /// A ceiling, not a page size: well past the 622 recipes the catalogue
    /// holds, so the opening list is all of them. Passed to
    /// `browseRecipes(limit:offset:)` because its default is 60.
    static let browseLimit = 10_000

    /// The count the stepper starts at for a recipe with no stated yield.
    static let defaultServings: Double = 4

    /// A macro as a whole number for display, rounded half away from zero.
    /// A value that is not a number reads as a dash rather than a zero.
    static func whole(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return String(Int(value.rounded()))
    }

    /// The list row's macro line.
    static func listSummary(_ recipe: CatalogRecipe) -> String {
        if let calories = recipe.caloriesPerServing {
            return "\(whole(calories)) kcal per serving"
        }
        // Said in the list, not only the detail, so a browsing eye never reads
        // a whole-dish figure as a portion.
        if recipe.needsServings { return "Macros for the whole dish" }
        return "No macros"
    }

    /// The detail's per-serving macro line.
    static func macroLine(_ facts: NutritionFacts) -> String {
        "\(whole(facts.calories)) kcal · P \(whole(facts.proteinG)) · C \(whole(facts.carbsG)) · F \(whole(facts.fatG))"
    }

    /// True whenever the source stated no yield. Wider than the kit's
    /// `needsServings`, which also needs whole-dish macros: that is the
    /// question of whether there is anything to divide, and this one is
    /// whether there is a count to choose.
    static func asksForServings(_ recipe: CatalogRecipe) -> Bool {
        recipe.servings == nil
    }

    /// What the stepper says beneath itself. Without macros there are no
    /// whole-dish figures to describe, so that case has its own sentence. Both
    /// are this app's Android build's, word for word: change them in both
    /// builds or in neither.
    static func servingsNote(_ recipe: CatalogRecipe) -> String {
        recipe.needsServings
            ? "This book states no yield, so the macros below are for the whole dish. Set how many it serves and they divide."
            : "This book states no yield. Set how many it serves."
    }

    /// Where the stepper starts: the stated yield, or the default.
    static func startingServings(_ recipe: CatalogRecipe) -> Double {
        recipe.servings ?? defaultServings
    }

    /// The count saved on Add. A stated yield always wins; otherwise it is the
    /// stepper's value, which is shown for every such recipe.
    static func servingsToSave(_ recipe: CatalogRecipe, chosen: Double) -> Double {
        recipe.servings ?? chosen
    }
}
