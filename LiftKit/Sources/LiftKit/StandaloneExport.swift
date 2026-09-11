import Foundation

/// Encodes the standalone food log into QR-sized base64url strings.
///
/// The payload is **self-contained**: it carries food names and per-100 g
/// macros rather than identifiers, because nothing downstream can resolve an
/// identifier. The PWA's `foods.json` has no id field at all, its data and
/// `lift-ios`'s `food.db` are independent derivations of USDA sharing no
/// identifiers, and `recipe:` ids point into the phone's private store.
///
/// Shape (`v`, `z`, `fd`, `e`, `p` are a wire contract):
/// ```
/// { "v": 1, "z": 1757500800,
///   "fd": [["Chicken breast, roasted", 165, 31, 3.6, 0, 0]],
///   "e":  [[0, 140, 2, 1757486400]],
///   "p":  [1, 3] }
/// ```
public enum StandaloneExport {

    /// 57 entries of realistic shape fit under the spec's 800-byte
    /// scannable ceiling once DEFLATEd. 50 is that rounded down.
    public static let maxEntriesPerCode = 50

    /// `SHARE-FORMAT`'s integer convention. `FoodLogMeal` is a string enum on
    /// the wire this repo already speaks, so the two have to be mapped.
    public static func mealIndex(_ meal: FoodLogMeal) -> Int {
        switch meal {
        case .breakfast: return 0
        case .lunch:     return 1
        case .dinner:    return 2
        case .snack:     return 3
        }
    }

    public static func codes(for entries: [LoggedFood],
                             exportedAt: Date = .now) -> [String] {
        guard !entries.isEmpty else { return [] }

        let chunks = stride(from: 0, to: entries.count, by: maxEntriesPerCode).map {
            Array(entries[$0 ..< min($0 + maxEntriesPerCode, entries.count)])
        }

        return chunks.enumerated().compactMap { index, chunk in
            encode(chunk, exportedAt: exportedAt,
                   position: [index + 1, chunks.count])
        }
    }

    private static func encode(_ entries: [LoggedFood],
                               exportedAt: Date,
                               position: [Int]) -> String? {
        // One dictionary row per distinct food, entries referring to it by
        // index. A user logs the same handful of foods repeatedly, so this is
        // what keeps a week's log inside one code.
        var order: [WatchFood] = []
        var indexOf: [WatchFood: Int] = [:]
        var tuples: [[Any]] = []

        for entry in entries {
            let index: Int
            if let known = indexOf[entry.food] {
                index = known
            } else {
                index = order.count
                indexOf[entry.food] = index
                order.append(entry.food)
            }
            tuples.append([index, entry.grams, mealIndex(entry.meal),
                           Int(entry.loggedAt.timeIntervalSince1970)])
        }

        let dictionary = order.map { [$0.name, $0.kcal, $0.protein, $0.fat, $0.carbs, $0.fibre] as [Any] }
        let payload: [String: Any] = [
            "v": 1,
            "z": Int(exportedAt.timeIntervalSince1970),
            "fd": dictionary,
            "e": tuples,
            "p": position,
        ]

        guard let json = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys]),
              let deflated = CompactEncoding.deflateRaw(json)
        else { return nil }
        return CompactEncoding.base64URL(deflated)
    }
}
