import Foundation

/// The USDA SR Legacy library the PWA bundles (`lift/foods.json`), carried on
/// the watch so a user who has never paired a LIFT iPhone can still log food.
///
/// Same file as the PWA's, verbatim, so a food logged here and a food logged
/// there carry the same name — which matters because the export payload
/// identifies foods by name, there being no shared identifier between the
/// PWA's data and LIFT iOS's (see the spec's Payload format section).
///
/// Records are bare positional arrays:
///   [name, categoryIndex, kcal, protein, fat, carbs, fibre]
public final class WatchFoodLibrary {

    /// A single parsed copy of the bundled library, shared by every call
    /// site. `FoodSearchView` used to construct its own `WatchFoodLibrary()`
    /// as a stored `let`, but `NavigationLink(_:destination:)` builds its
    /// destination view eagerly, so that `let` re-ran on every enclosing
    /// `StartWorkoutView.body` evaluation -- every Focus-picker change, every
    /// `@Published` change on `WorkoutSessionModel` -- re-parsing the 634 KB
    /// library each time (measured: 40.8 ms and 7,793 allocations per
    /// construction, on the main thread, discarded immediately). Parsing
    /// once, lazily, on first access removes that cost entirely.
    public static let shared = WatchFoodLibrary()

    private let foods: [WatchFood]

    // `public init(bundle: Bundle = .module)` as specified does not compile:
    // SwiftPM's generated `Bundle.module` accessor is `internal`, and Swift
    // rejects an internal symbol in a public default-argument expression even
    // from within the defining module. Splitting into a designated
    // initializer plus a zero-argument convenience initializer keeps both
    // call sites the brief wants (`WatchFoodLibrary()` and
    // `WatchFoodLibrary(bundle:)`) without that restriction, since it does
    // not apply to a function body.
    public convenience init() {
        self.init(bundle: .module)
    }

    public init(bundle: Bundle) {
        guard let url = bundle.url(forResource: "foods", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["foods"] as? [[Any]]
        else {
            self.foods = []
            return
        }

        self.foods = rows.compactMap { row in
            guard row.count >= 7, let name = row[0] as? String else { return nil }
            func number(_ index: Int) -> Double {
                (row[index] as? NSNumber)?.doubleValue ?? 0
            }
            return WatchFood(name: name, kcal: number(2), protein: number(3),
                             fat: number(4), carbs: number(5), fibre: number(6))
        }
    }

    public var count: Int { foods.count }

    /// Case-insensitive substring match, capped. A blank query returns
    /// nothing rather than everything: 7,793 rows is not a wrist list, the
    /// same reasoning `RecentFoodsListView` already cites for keeping its
    /// own list short.
    public func search(_ query: String, limit: Int = 30) -> [WatchFood] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        var hits: [WatchFood] = []
        for food in foods where food.name.lowercased().contains(needle) {
            hits.append(food)
            if hits.count == limit { break }
        }
        return hits
    }
}
