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

    /// The spec's scannable ceiling for a single QR code.
    ///
    /// A fixed *entry* count cannot honor this: the payload's cost is
    /// dominated by the food dictionary (`fd`), not the entry list (`e`), and
    /// real USDA names run far longer than a synthetic fixture's. Eight real
    /// names alone (median 51 characters, e.g. "Fish, tuna, white, canned in
    /// oil, without salt, drained solids") push a 50-entry code to roughly
    /// 1052 bytes -- 30% over this ceiling -- while only ~21 such entries
    /// actually fit. `codes(for:)` therefore chunks by measuring the real
    /// encoded size of each candidate chunk, not by counting entries.
    public static let maxCodeBytes = 800

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

        // `p`'s digit width depends on the final chunk count, which isn't
        // known until chunking is done -- but fitting a chunk to the byte
        // budget needs to know `p`'s width first. Break that cycle with a
        // placeholder position sized to the widest `p` could ever legally
        // be: a log can never split into more chunks than it has entries
        // (every chunk holds at least one), so no real index or total can
        // have more digits than `entries.count` does. Measuring against that
        // upper bound only ever *under*-states the room left in a chunk, so
        // substituting the true (same-or-narrower) position afterward can
        // only hold or shrink each result -- never push it past what was
        // measured here.
        let placeholder = [entries.count, entries.count]

        var chunks: [[LoggedFood]] = [[entries[0]]]
        for entry in entries.dropFirst() {
            let candidate = chunks[chunks.count - 1] + [entry]
            if encode(candidate, exportedAt: exportedAt, position: placeholder).count <= maxCodeBytes {
                chunks[chunks.count - 1] = candidate
            } else {
                // Start a fresh chunk with just this entry. If `entry` alone
                // is still over budget once it is finally on its own, the
                // next iteration (or the loop ending, for the last entry)
                // flushes it as a one-entry chunk regardless -- a single
                // oversized entry always reaches exactly one code, never
                // blocks the entries after it, and never loops.
                chunks.append([entry])
            }
        }

        let total = chunks.count
        return chunks.enumerated().map { index, chunk in
            encode(chunk, exportedAt: exportedAt, position: [index + 1, total])
        }
    }

    private static func encode(_ entries: [LoggedFood],
                               exportedAt: Date,
                               position: [Int]) -> String {
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

        // `JSONSerialization` only fails to encode a payload containing a
        // value it cannot represent (NaN/infinite `Double`, a cycle, and so
        // on). Every value built above is a `String`, `Int`, or a `Double`
        // sourced from `WatchFood`/`LoggedFood`, so this cannot actually
        // throw for real input; the empty-`Data` fallback just keeps this
        // function total instead of reintroducing an optional for a case
        // that cannot occur.
        let json = (try? JSONSerialization.data(withJSONObject: payload,
                                                 options: [.sortedKeys])) ?? Data()

        // `CompactEncoding.deflateRaw` documents its `nil` return as "the
        // caller sends the payload uncompressed in that case" -- it only
        // happens when compressing would make the payload *larger* than it
        // started. The previous implementation instead dropped the whole
        // chunk here via `compactMap`, which silently deleted a code out of
        // the middle of a numbered sequence while every other code in that
        // sequence kept advertising the pre-drop `p` total (e.g. codes
        // "1 of 3" and "3 of 3" with no scannable "2 of 3" ever produced).
        // Falling back to the raw JSON bytes instead keeps every entry on
        // the wire and keeps every `p` truthful. This does not add a
        // compressed/uncompressed flag to the wire envelope -- there isn't
        // one today -- see the task report for why that's a deliberate
        // choice, not an oversight.
        let body = CompactEncoding.deflateRaw(json) ?? json
        return CompactEncoding.base64URL(body)
    }
}
