import Foundation
import LiftCore

/// `rf` in a coach's plan link: the Road Food item ids they are happy with
/// (`coach/PLAN-FORMAT.md` "Road picks").
///
/// **Why it is read here and not by `PlanLinkCodec`.** `PlanPayload` is
/// LiftKit's, and LiftKit is pinned to an exact tag that Coach iOS consumes
/// too, so a field there is a kit release plus a version bump in two shipped
/// apps. `rf` is a flat list of strings with no cross-app rule attached to it
/// beyond "skip what you do not know", so it is read app-side, from the same
/// fragment, by the twelve lines below. Coach iOS writes it the mirror way
/// (`RoadPickWire`), and the fixture both read is the contract between them.
/// The day a third field wants the same treatment, that is when to pay for a
/// kit tag.
///
/// **It is deliberately lenient and never throws.** By the time this is asked
/// anything, `PlanLinkCodec.decode` has already accepted the fragment: the
/// envelope is good, the payload is a plan, and it is addressed to this
/// phone. A `rf` that is missing, not a list, or full of junk is *no picks*,
/// never a plan that will not open -- losing a coach's whole week over a
/// malformed picks list would be the wrong trade by a mile.
enum RoadPickLink {

    /// The picks in a plan fragment -- everything after the `#`, without it.
    /// Empty when there is no `rf`, which PLAN-FORMAT calls silence about
    /// picks rather than a retraction.
    static func ids(inFragment fragment: String) -> [String] {
        guard fragment.count >= 2 else { return [] }
        let codec = fragment[fragment.index(after: fragment.startIndex)]
        // As `PlanLinkCodec` does: the payload is base64url, so the first
        // character outside that alphabet marks where it ends.
        let body = String(fragment.dropFirst(2).prefix { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
        })
        guard let raw = CompactEncoding.base64URLDecode(body) else { return [] }
        switch codec {
        case "z":
            guard let inflated = CompactEncoding.inflateRaw(raw) else { return [] }
            return ids(inJSON: inflated)
        case "u":
            return ids(inJSON: raw)
        default:
            return []
        }
    }

    /// The picks in a decoded payload's JSON.
    static func ids(inJSON json: Data) -> [String] {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: json) else { return [] }
        return normalise(envelope.rf ?? [])
    }

    /// Trimmed, no blanks, no duplicates, in the order the coach ticked them
    /// -- the one order a coach authored. Coach web's `normalise`.
    static func normalise(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap { raw in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return id
        }
    }

    /// Only `rf`, and only as strings: a number or an object in the list costs
    /// that entry, not the list. `[String?]` rather than `[String]` so one bad
    /// element does not fail the whole decode.
    private struct Envelope: Decodable {
        let rf: [String]?

        private enum CodingKeys: String, CodingKey { case rf }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rf = (try? c.decodeIfPresent([Lenient].self, forKey: .rf))??.compactMap(\.value)
        }

        private struct Lenient: Decodable {
            let value: String?
            init(from decoder: Decoder) throws {
                value = try? decoder.singleValueContainer().decode(String.self)
            }
        }
    }
}
