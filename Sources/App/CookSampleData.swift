#if DEBUG
import Foundation
import SwiftData
import LiftCore

/// Realistic COOK data for screenshots and manual testing.
///
/// DEBUG only, and deliberately so — this is not COACH's "Load a sample
/// client", which is a real shipped feature because a trainer needs to see a
/// roster working before asking a client to send anything. Nobody needs fake
/// recipes in a shipping build; they have their own.
///
/// Wiped and rebuilt on each call so repeated runs produce identical
/// screenshots.
enum CookSampleData {

    static func load(into context: ModelContext) {
        wipe(context)

        let recipes = catalogue.map { spec -> Recipe in
            let recipe = Recipe(
                name: spec.name,
                servings: spec.servings,
                steps: spec.steps,
                nutritionPerServing: spec.nutrition
            )
            context.insert(recipe)
            for (index, line) in spec.ingredients.enumerated() {
                let ingredient = IngredientParser.parse(line, sortOrder: index)
                ingredient.recipe = recipe
                context.insert(ingredient)
            }
            return recipe
        }

        plan(recipes, in: context)
        try? context.save()
    }

    private static func wipe(_ context: ModelContext) {
        for recipe in (try? context.fetch(FetchDescriptor<Recipe>())) ?? [] {
            context.delete(recipe)
        }
        for meal in (try? context.fetch(FetchDescriptor<PlannedMeal>())) ?? [] {
            context.delete(meal)
        }
        for check in (try? context.fetch(FetchDescriptor<ShoppingListCheck>())) ?? [] {
            context.delete(check)
        }
    }

    /// A plausible few days: not every slot filled, because a real plan never
    /// is, and a screenshot of a perfectly full week looks like a mock-up.
    private static func plan(_ recipes: [Recipe], in context: ModelContext) {
        guard recipes.count >= 4 else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        let schedule: [(day: Int, meal: MealType, recipe: Int, servings: Double)] = [
            (0, .breakfast, 0, 1),
            (0, .dinner,    2, 2),
            (1, .breakfast, 0, 1),
            (1, .lunch,     1, 1),
            (1, .dinner,    3, 2),
            (2, .lunch,     1, 1),
            (2, .dinner,    2, 2),
            (3, .breakfast, 4, 1),
            (3, .dinner,    3, 2)
        ]

        for item in schedule {
            guard item.recipe < recipes.count,
                  let day = calendar.date(byAdding: .day, value: item.day, to: today),
                  let at = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)
            else { continue }

            context.insert(PlannedMeal(
                recipe: recipes[item.recipe],
                mealType: item.meal,
                plannedFor: at,
                servings: item.servings
            ))
        }
    }

    private struct Spec {
        let name: String
        let servings: Double
        let nutrition: NutritionFacts
        let ingredients: [String]
        let steps: [String]
    }

    private static let catalogue: [Spec] = [
        Spec(
            name: "Peanut Butter Banana Creami",
            servings: 1,
            nutrition: NutritionFacts(calories: 342, proteinG: 31, carbsG: 38, fatG: 8, fiberG: 4),
            ingredients: [
                "1 banana",
                "30 g whey protein",
                "1 tbsp peanut butter powder",
                "240 ml skim milk",
                "1 pinch salt"
            ],
            steps: [
                "Blend everything until smooth.",
                "Freeze in the pint 24 hours.",
                "Spin on Lite Ice Cream, then respin with a splash of milk."
            ]
        ),
        Spec(
            name: "Chicken Rice Bowl",
            servings: 2,
            nutrition: NutritionFacts(calories: 512, proteinG: 44, carbsG: 58, fatG: 11, fiberG: 5),
            ingredients: [
                "400 g chicken thigh",
                "300 g jasmine rice",
                "2 tbsp soy sauce",
                "1 tbsp sesame oil",
                "2 cloves garlic",
                "200 g tenderstem broccoli"
            ],
            steps: [
                "Rice on first.",
                "Sear the thighs hard, then garlic and soy off the heat.",
                "Steam the broccoli over the rice for the last four minutes."
            ]
        ),
        Spec(
            name: "Beef Chilli",
            servings: 4,
            nutrition: NutritionFacts(calories: 438, proteinG: 36, carbsG: 31, fatG: 19, fiberG: 9),
            ingredients: [
                "500 g lean beef mince",
                "1 can kidney beans",
                "1 can chopped tomatoes",
                "1 onion",
                "2 cloves garlic",
                "1 tbsp smoked paprika",
                "2 tsp cumin"
            ],
            steps: [
                "Brown the mince properly — do it in two batches.",
                "Onion, garlic, spices, then the tins.",
                "Forty minutes with the lid off."
            ]
        ),
        Spec(
            name: "Overnight Oats",
            servings: 1,
            nutrition: NutritionFacts(calories: 388, proteinG: 28, carbsG: 47, fatG: 10, fiberG: 7),
            ingredients: [
                "80 g rolled oats",
                "25 g whey protein",
                "200 ml milk",
                "1 tbsp chia seeds",
                "100 g blueberries"
            ],
            steps: ["Stir, jar, fridge overnight."]
        ),
        Spec(
            name: "Salmon and Sweet Potato",
            servings: 2,
            nutrition: NutritionFacts(calories: 546, proteinG: 40, carbsG: 42, fatG: 23, fiberG: 6),
            ingredients: [
                "2 salmon fillets",
                "500 g sweet potato",
                "1 tbsp olive oil",
                "1 lemon",
                "200 g green beans"
            ],
            steps: [
                "Sweet potato in at 200C for 35 minutes.",
                "Salmon joins for the last 12.",
                "Beans in the last four."
            ]
        )
    ]
}
#endif
