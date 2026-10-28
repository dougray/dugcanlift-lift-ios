import Foundation
import LiftCore

/// The bar a lift is loaded on, which decides what the bar itself weighs.
///
/// Read from the name as well as the equipment, because the exercise data
/// files every Smith machine lift under "machine" (and one under "barbell"),
/// some EZ-bar curls under "barbell", and has no trap bar at all.
enum BarKind: String, CaseIterable, Codable, Identifiable {
    case barbell, ezBar, trapBar, smith

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .barbell: "Barbell"
        case .ezBar: "EZ bar"
        case .trapBar: "Trap bar"
        case .smith: "Smith machine"
        }
    }

    /// Nil for anything that is not loaded with plates on both ends of a bar.
    /// A landmine is: one end sits in the floor, so "per side" means nothing.
    static func of(name: String, equipment: String?) -> BarKind? {
        let words = Self.normalised(name + " " + (equipment ?? ""))
        if words.contains(" landmine ") { return nil }
        if words.contains(" smith ") { return .smith }
        if words.contains(" trap bar ") || words.contains(" hex bar ") { return .trapBar }
        if words.contains(" ez bar ") || words.contains(" ez curl bar ") { return .ezBar }
        if Self.normalised(equipment ?? "").contains(" barbell ") { return .barbell }
        return nil
    }

    /// Lowercased, punctuation to spaces, padded so a phrase matches whole
    /// words only: "EZ-Bar" and "e-z curl bar" both become " ez bar ".
    private static func normalised(_ text: String) -> String {
        var out = text.lowercased()
            .replacingOccurrences(of: "e-z", with: "ez")
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
        out = out.split(separator: " ").joined(separator: " ")
        return " \(out) "
    }
}

/// The plates someone owns and what their bars weigh, in one unit. Kept per
/// unit because plates are made in one: a pound gym's 45s are not 20 kg.
struct PlateSetup: Codable, Equatable {
    struct Plate: Codable, Equatable {
        var weight: Double
        /// Pairs, because a plate is loaded on both ends. Zero is "not owned".
        var pairs: Int
    }

    /// Heaviest first.
    private(set) var plates: [Plate]
    private var bars: [String: Double]

    static let mostPairs = 20

    /// A commercial gym: plenty of every common plate, none of the fractional
    /// ones, which are there to be switched on.
    static func standard(for unit: WeightUnit) -> PlateSetup {
        let plenty = 10
        switch unit {
        case .pounds:
            return PlateSetup(
                plates: [45, 35, 25, 10, 5, 2.5].map { Plate(weight: $0, pairs: plenty) }
                    + [Plate(weight: 1.25, pairs: 0)],
                bars: [BarKind.barbell.rawValue: 45, BarKind.ezBar.rawValue: 25,
                       BarKind.trapBar.rawValue: 45, BarKind.smith.rawValue: 15])
        case .kilograms:
            return PlateSetup(
                plates: [25, 20, 15, 10, 5, 2.5, 1.25].map { Plate(weight: $0, pairs: plenty) }
                    + [Plate(weight: 0.5, pairs: 0)],
                bars: [BarKind.barbell.rawValue: 20, BarKind.ezBar.rawValue: 10,
                       BarKind.trapBar.rawValue: 20, BarKind.smith.rawValue: 7])
        }
    }

    func barWeight(_ bar: BarKind) -> Double { bars[bar.rawValue] ?? 0 }

    mutating func setBar(_ bar: BarKind, weight: Double) {
        bars[bar.rawValue] = max(0, weight)
    }

    func pairs(of weight: Double) -> Int {
        plates.first { $0.weight == weight }?.pairs ?? 0
    }

    /// A weight not on the rack yet is added to it, in order.
    mutating func set(pairs: Int, of weight: Double) {
        let pairs = min(max(0, pairs), Self.mostPairs)
        if let index = plates.firstIndex(where: { $0.weight == weight }) {
            plates[index].pairs = pairs
        } else if weight > 0 {
            plates.append(Plate(weight: weight, pairs: pairs))
            plates.sort { $0.weight > $1.weight }
        }
    }

    // MARK: - Stored

    static func key(for unit: WeightUnit) -> String { "plateSetup.\(unit.rawValue)" }

    /// Unread or unreadable is the standard rack, never an empty one: an empty
    /// rack would answer every set with "your plates make the bar".
    static func load(for unit: WeightUnit, from defaults: UserDefaults = .standard) -> PlateSetup {
        guard let data = defaults.data(forKey: key(for: unit)),
              let setup = try? JSONDecoder().decode(PlateSetup.self, from: data)
        else { return standard(for: unit) }
        return setup
    }

    func save(for unit: WeightUnit, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key(for: unit))
    }
}

/// What to put on the bar for a set: the fewest plates a side that reach the
/// weight from what is owned, or, when nothing owned reaches it exactly, the
/// heaviest load under it and how far short that is.
///
/// Not greedy. Greedy takes the biggest plate first, and with a limited rack
/// that can miss a load the rack can make (45 + 15 from no 15s, when two 30s
/// were right there).
enum PlateMath {
    enum Load: Equatable {
        case nothing
        case lighterThanTheBar
        case justTheBar
        /// `perSide` heaviest first; `total` is what that loads, bar included.
        case plates(perSide: [Double], total: Double, shortBy: Double)

        var perSide: [Double] {
            if case let .plates(perSide, _, _) = self { return perSide }
            return []
        }

        func line(unit: WeightUnit) -> String? {
            switch self {
            case .nothing:
                return nil
            case .lighterThanTheBar:
                return "Lighter than the bar"
            case .justTheBar:
                return "Just the bar"
            case let .plates(perSide, total, shortBy):
                let plates = "Per side: " + perSide.map(PlateMath.text).joined(separator: " · ")
                guard shortBy > 0 else { return plates }
                return "Your plates make \(PlateMath.text(total)) \(unit.abbreviation), "
                    + "\(PlateMath.text(shortBy)) short. \(plates)"
            }
        }
    }

    /// Every plate is a whole number of these, in either unit (1.25, 0.5).
    private static let step = 0.25

    /// `total` in the setup's own unit, bar included.
    static func load(total: Double, bar: BarKind, setup: PlateSetup) -> Load {
        let total = (total * 100).rounded() / 100
        guard total > 0 else { return .nothing }
        let barWeight = setup.barWeight(bar)
        if total < barWeight { return .lighterThanTheBar }
        if total == barWeight { return .justTheBar }

        let target = Int(((total - barWeight) / 2 / step + 1e-6).rounded(.down))
        let owned = setup.plates
            .filter { $0.pairs > 0 && $0.weight > 0 }
            .map { (units: Int(($0.weight / step).rounded()), pairs: $0.pairs) }

        // fewest[v]: the fewest plates making exactly v steps a side, with
        // the heaviest-first list that does it. Bounded by the pairs owned.
        var fewest: [[Int]?] = Array(repeating: nil, count: target + 1)
        fewest[0] = []
        for plate in owned where plate.units <= target {
            var next = fewest
            for value in 0...target {
                guard let base = fewest[value] else { continue }
                for count in 1...plate.pairs {
                    let reached = value + count * plate.units
                    guard reached <= target else { break }
                    let candidate = base + Array(repeating: plate.units, count: count)
                    if better(candidate, than: next[reached]) { next[reached] = candidate }
                }
            }
            fewest = next
        }

        guard let reached = (0...target).last(where: { fewest[$0] != nil }),
              let units = fewest[reached], !units.isEmpty
        else { return .justTheBar }
        let perSide = units.sorted(by: >).map { Double($0) * step }
        let loaded = barWeight + 2 * Double(reached) * step
        return .plates(perSide: perSide, total: loaded,
                       shortBy: ((total - loaded) * 100).rounded() / 100)
    }

    /// Fewer plates, then the heavier plates first.
    private static func better(_ candidate: [Int], than current: [Int]?) -> Bool {
        guard let current else { return true }
        if candidate.count != current.count { return candidate.count < current.count }
        return candidate.sorted(by: >).lexicographicallyPrecedes(current.sorted(by: >), by: >)
    }

    static func text(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }
}
