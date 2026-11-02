import Foundation

/// A meal put together at one place before it is ordered: a sandwich, a side
/// and a milk, totalled against what is left of today (`RemainingMacros`).
///
/// Only items that can be logged can be added (`RoadFoodRanking
/// .cannotLogReason`), so every item here has its calories, protein, carbs and
/// fat, and a total is never a partial sum passed off as a whole. Logging the
/// meal logs each item as its own entry, exactly as "Log it" would, so the day
/// reads the same either way and an item can be removed from it later on its
/// own.
///
/// A value type with no view in it, for the reason `MacroFields` is one in
/// Coach: it decides a number a person is told about their day.
struct RoadFoodMeal: Equatable {
    /// Item ids and how many of each, in the order they were first added.
    private(set) var lines: [(id: String, count: Int)] = []

    static func == (a: RoadFoodMeal, b: RoadFoodMeal) -> Bool {
        a.lines.map(\.id) == b.lines.map(\.id) && a.lines.map(\.count) == b.lines.map(\.count)
    }

    var isEmpty: Bool { lines.isEmpty }
    var itemCount: Int { lines.reduce(0) { $0 + $1.count } }

    func count(of id: String) -> Int { lines.first { $0.id == id }?.count ?? 0 }

    mutating func add(_ item: RoadFoodItem) {
        guard RoadFoodRanking.cannotLogReason(item) == nil else { return }
        if let index = lines.firstIndex(where: { $0.id == item.id }) {
            lines[index].count += 1
        } else {
            lines.append((item.id, 1))
        }
    }

    mutating func remove(_ item: RoadFoodItem) {
        guard let index = lines.firstIndex(where: { $0.id == item.id }) else { return }
        lines[index].count -= 1
        if lines[index].count <= 0 { lines.remove(at: index) }
    }

    mutating func clear() { lines = [] }

    /// The items to log, one per serving, in the order they were added. An id
    /// this place no longer lists is dropped rather than logged as nothing.
    func items(from menu: [RoadFoodItem]) -> [RoadFoodItem] {
        lines.flatMap { line in
            menu.first { $0.id == line.id }.map { Array(repeating: $0, count: line.count) } ?? []
        }
    }

    struct Total: Equatable {
        let kcal: Double
        let proteinG: Double
    }

    func total(from menu: [RoadFoodItem]) -> Total {
        let items = items(from: menu)
        return Total(kcal: items.reduce(0) { $0 + ($1.kcal ?? 0).rounded() },
                     proteinG: items.reduce(0) { $0 + ($1.proteinG ?? 0).rounded() })
    }

    /// "2 items · 830 kcal · 61 g protein · fits, 410 kcal to spare", or
    /// "… · 120 kcal over what is left". Said, never coloured.
    func line(from menu: [RoadFoodItem], remaining: RemainingMacros?) -> String {
        let total = total(from: menu)
        let count = itemCount
        var parts = [count == 1 ? "1 item" : "\(count) items",
                     "\(Int(total.kcal)) kcal", "\(Int(total.proteinG)) g protein"]
        if let remaining {
            let left = Double(remaining.wholeCalories) - total.kcal
            if left >= 0 {
                parts.append(left == 0 ? "uses exactly what is left" : "fits, \(Int(left)) kcal to spare")
            } else {
                parts.append("\(Int(-left)) kcal over what is left")
            }
        }
        return parts.joined(separator: " · ")
    }
}
