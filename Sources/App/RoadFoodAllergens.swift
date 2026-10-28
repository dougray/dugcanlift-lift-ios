import Foundation

/// Avoiding allergens at a Road Food place: what is hidden, what is shown, and
/// what is said about an item the chart is silent on.
///
/// The data is what the chain's own allergen chart says an item **contains**
/// (`dugcanlift-kit/data/README.md`); "may contain" and shared-fryer notes are
/// not in it. So the rules are deliberately one-sided:
///
/// - An item that contains something avoided is **hidden**, and counted, so a
///   short list is never mistaken for a short menu.
/// - An item is **never claimed free** of an allergen the chart does not cover
///   or does not state for it. It stays on the list, and its row says "Milk not
///   stated" in words. A filter that hid only what it knew about and implied the
///   rest was safe would be worse than no filter.
/// - Nothing here says "safe". The screen says the chart is the chain's, and
///   that cross-contact is not covered.
///
/// A value type with no view in it, because this decides what someone with an
/// allergy is shown. `RoadFoodAllergensTests` pins it.
enum RoadFoodAllergens {
    /// The US major allergens, in display order.
    static let all = ["milk", "egg", "fish", "shellfish", "tree-nuts", "peanuts", "wheat", "soy", "sesame"]

    static let storageKey = "roadFoodAvoid"

    static func label(_ allergen: String) -> String {
        switch allergen {
        case "tree-nuts": "Tree nuts"
        case "egg": "Egg"
        default: allergen.prefix(1).uppercased() + allergen.dropFirst()
        }
    }

    /// Known strings only, in display order, once each.
    static func known(_ list: [String]) -> [String] {
        let set = Set(list.map { $0.lowercased() })
        return all.filter(set.contains)
    }

    enum Verdict: Equatable {
        /// Contains at least one avoided allergen: hidden.
        case contains([String])
        /// Shown; these avoided allergens are not stated for it.
        case notStated([String])
        /// Shown; the chart covers every avoided allergen and lists none of them.
        case clear
    }

    static func verdict(_ item: RoadFoodItem, covered: [String], avoiding: Set<String>) -> Verdict {
        guard !avoiding.isEmpty else { return .clear }
        let avoided = all.filter(avoiding.contains)
        if let stated = item.allergens {
            let hit = avoided.filter(stated.contains)
            if !hit.isEmpty { return .contains(hit) }
            let unknown = avoided.filter { !covered.contains($0) }
            return unknown.isEmpty ? .clear : .notStated(unknown)
        }
        return .notStated(avoided)
    }

    struct Filtered: Equatable {
        let shown: [RoadFoodItem]
        /// How many were hidden, per avoided allergen that hid them.
        let hiddenCount: Int
    }

    static func filter(_ items: [RoadFoodItem], covered: [String], avoiding: Set<String>) -> Filtered {
        let shown = items.filter {
            if case .contains = verdict($0, covered: covered, avoiding: avoiding) { return false }
            return true
        }
        return Filtered(shown: shown, hiddenCount: items.count - shown.count)
    }

    /// "Contains milk, wheat, soy" / "Allergen chart lists none of these" /
    /// nil when the chart says nothing about the item.
    static func containsLine(_ item: RoadFoodItem) -> String? {
        guard let stated = item.allergens else { return nil }
        if stated.isEmpty { return "Contains none of the allergens its chart lists" }
        return "Contains " + ListFormatter.localizedString(byJoining: stated.map { label($0).lowercased() })
    }

    /// "Milk and egg not stated", for a shown row while something is avoided.
    static func notStatedLine(_ verdict: Verdict) -> String? {
        guard case let .notStated(list) = verdict, !list.isEmpty else { return nil }
        let names = ListFormatter.localizedString(byJoining: list.map { label($0).lowercased() })
        return names.prefix(1).uppercased() + names.dropFirst() + " not stated"
    }

    static func load(from defaults: UserDefaults = .standard) -> Set<String> {
        Set(known(defaults.stringArray(forKey: storageKey) ?? []))
    }

    /// Avoiding nothing removes the key.
    static func save(_ avoiding: Set<String>, to defaults: UserDefaults = .standard) {
        let list = known(Array(avoiding))
        if list.isEmpty { defaults.removeObject(forKey: storageKey) } else { defaults.set(list, forKey: storageKey) }
    }
}
