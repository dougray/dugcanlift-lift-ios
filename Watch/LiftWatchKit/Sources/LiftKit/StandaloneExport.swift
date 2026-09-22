import Foundation

/// Encodes the standalone food log into QR-sized base64url strings.
///
/// The payload is **self-contained**: it carries food names and per-100 g
/// macros rather than identifiers, because nothing downstream can resolve an
/// identifier. The PWA's `foods.json` has no id field at all, its data and
/// `lift-ios`'s `food.db` are independent derivations of USDA sharing no
/// identifiers, and `recipe:` ids point into the phone's private store.
///
/// Each emitted code is `<formatVersion><codec><base64url>` -- the same
/// envelope `SHARE-FORMAT` and `PLAN-FORMAT` already use, decoded by the
/// PWA's `frag.match(/^(\d+)([zu])([A-Za-z0-9_-]+)$/)`
/// (`lift/app.js`'s `decodeIncomingPlan`). `codec` is `z` for raw DEFLATE or
/// `u` when `CompactEncoding.deflateRaw` reports compression would have
/// grown the payload, in which case `base64url` wraps the *raw* JSON bytes
/// instead -- this is what makes that fallback path decodable by the reader
/// rather than poison. `formatVersion` (`1`) is deliberately redundant with
/// the payload's own `v` field below: `SHARE-FORMAT` carries the same
/// redundancy, and matching that existing convention wins over deduplicating
/// it away.
///
/// Payload shape (`v`, `z`, `fd`, `e`, `p` are a wire contract):
/// ```
/// { "v": 1, "z": 1757500800,
///   "fd": [["Chicken breast, roasted", 165, 31, 3.6, 0, 0]],
///   "e":  [[0, 140, 2, 1757486400]],
///   "p":  [1, 3] }
/// ```
public enum StandaloneExport {

    /// The spec's scannable ceiling for a single QR code -- measured on the
    /// full emitted string, envelope prefix (`1z`/`1u`) included, since
    /// that's what actually has to fit in the code.
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

    /// `SHARE-FORMAT`/`PLAN-FORMAT`'s envelope version. Shared as the single
    /// source for both the envelope prefix and the payload's `v` field so
    /// the two intentionally-redundant copies can never drift apart.
    private static let envelopeVersion = 1

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
            "v": envelopeVersion,
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

        return envelope(for: json)
    }

    /// Wraps `json` in the `<formatVersion><codec><base64url>` envelope.
    ///
    /// `CompactEncoding.deflateRaw` documents its `nil` return as "the
    /// caller sends the payload uncompressed in that case" -- it only
    /// happens when compressing would make the payload *larger* than it
    /// started. An earlier version of this encoder dropped the whole chunk
    /// in that case, which silently deleted a code out of the middle of a
    /// numbered sequence while every other code in that sequence kept
    /// advertising the pre-drop `p` total (e.g. codes "1 of 3" and "3 of 3"
    /// with no scannable "2 of 3" ever produced). Falling back to the raw
    /// JSON bytes under the `u` codec instead keeps every entry on the wire,
    /// keeps every `p` truthful, *and* stays decodable -- unlike silently
    /// sending compressed-looking bytes that were never actually
    /// compressed, which the reader's `deflate-raw` decompressor would
    /// simply fail on.
    ///
    /// `deflate` is injectable (default `CompactEncoding.deflateRaw`) purely
    /// so `StandaloneExportTests` can force the `u` branch: no JSON shape
    /// this encoder actually produces was found to make the real
    /// `deflateRaw` return nil (only large, uniformly-random full-byte-range
    /// data reliably does), so exercising that branch through the public API
    /// alone isn't possible. `internal` rather than `private` so
    /// `@testable import` can reach it; production callers never pass this
    /// argument and always get the real codec.
    static func envelope(for json: Data,
                         deflate: (Data) -> Data? = CompactEncoding.deflateRaw) -> String {
        let deflated = deflate(json)
        let codec: Character = deflated != nil ? "z" : "u"
        let body = deflated ?? json
        return "\(envelopeVersion)\(codec)\(CompactEncoding.base64URL(body))"
    }
}
