import Foundation
import LiftCore

/// Finds a coach's plan fragment in whatever reached LIFT: a pasted string, a
/// URL shared from Safari or Messages, a message body with the link somewhere
/// inside it, or LIFT's own `dugcanliftlift://` URL.
///
/// Compiled into both the app and the share extension, so it imports nothing
/// but Foundation and `LiftCore` -- no SwiftData, no views. Paste a Plan Link,
/// the share extension and `onOpenURL` all go through `fragment(in:)`, so a
/// link that opens one way opens every way, and one that fails, fails alike.
///
/// The rule, in order:
/// 1. The first LIFT plan link anywhere in the text wins. That is
///    `https://www.dugcanlift.com/lift/#1z...` (scheme optional, `www.`
///    optional, host case-insensitive) or `dugcanliftlift://plan#1z...`.
///    Text around it is ignored, including a `#` in the prose before it
///    ("Week #3: ..."), which is why this does not simply split on the last
///    `#`.
/// 2. Otherwise the text itself may be a bare fragment, as copied on its own:
///    trimmed, an optional leading `#`, then `1z`/`1u`.
/// 3. Anything else is not a LIFT plan link -- including another site's URL
///    that happens to carry a `#1z...` fragment, and including the lifter's
///    own `/coach/#1z...` log link, which travels the other way.
///
/// In both accepted cases the fragment ends at the first character outside
/// base64url, so a mail client's `<...>` or a sentence's full stop is dropped.
/// Whether the fragment actually decodes, and whether the plan inside is
/// addressed to this phone, is `PlanLinkCodec`'s call, not this one's.
///
/// **This is a port of Coach iOS's `ShareLinkExtractor`, deliberately, and the
/// two must not drift.** Coach looks for `/coach/#...` log links and LIFT looks
/// for `/lift/#...` plan links: the destinations differ but the rule -- host
/// anchoring, first-link-wins, the bare-fragment fallback, where a fragment
/// ends -- is one rule, and `PlanLinkExtractorTests` is a case-for-case port of
/// `ShareLinkExtractorTests`. Change one, change both. It is not in LiftKit
/// because moving it there is a kit tag plus a pinned-version bump in two
/// shipped apps, and the second app's copy is compiled into a shipped share
/// extension; if a third app ever needs this rule, that is the moment to pay
/// that cost rather than write a third copy.
enum PlanLinkExtractor {

    /// LIFT's own URL scheme, declared in project.yml's `CFBundleURLTypes`.
    /// Deliberately not `dugcanliftcoach`, which is Coach iOS's and would
    /// collide on a phone with both apps installed -- iOS gives a scheme
    /// claimed twice to whichever app it pleases.
    static let urlScheme = "dugcanliftlift"

    /// The host part of the URL this scheme builds: `dugcanliftlift://plan#...`.
    static let urlHost = "plan"

    static func fragment(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        if let match = linkPattern.firstMatch(in: text, range: range),
           let fragmentRange = Range(match.range(at: 1), in: text) {
            return String(text[fragmentRange])
        }

        var bare = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if bare.hasPrefix("#") { bare = bare.dropFirst() }
        guard bare.hasPrefix("1z") || bare.hasPrefix("1u") else { return nil }
        let fragment = bare.prefix { isBase64URLCharacter($0) }
        return fragment.count > 2 ? String(fragment) : nil
    }

    /// Extracts and decodes in one step.
    static func payload(in text: String, expectedLifterID: String) throws -> PlanPayload {
        guard let fragment = fragment(in: text) else { throw PlanLinkError.malformedFragment }
        return try PlanLinkCodec.decode(fragment: fragment, expectedLifterID: expectedLifterID)
    }

    /// "Plan from Doug · 1 workout" -- what the share extension asks the lifter
    /// to confirm, and what Paste a Plan Link shows before they open it.
    ///
    /// Counts the same four things `PlanImporter.summary` does, but computed
    /// here rather than there: `PlanImporter` imports SwiftData, and this file
    /// is compiled into the share extension, which must not.
    static func summary(of payload: PlanPayload, roadPickCount: Int = 0) -> String {
        let name = payload.n.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = ["Plan from \(name.isEmpty ? "your coach" : name)"]
        func count(_ n: Int, _ singular: String, _ plural: String) {
            if n > 0 { parts.append("\(n) \(n == 1 ? singular : plural)") }
        }
        count(payload.w?.count ?? 0, "workout", "workouts")
        count(payload.r?.count ?? 0, "recipe", "recipes")
        count(payload.m?.count ?? 0, "planned meal", "planned meals")
        count(payload.k?.count ?? 0, "scheduled day", "scheduled days")
        // `rf` is not on `PlanPayload` (see `RoadPickLink`), so the caller
        // passes the count. Named like the other halves, so a send that is
        // only picks is not described as an empty plan.
        count(roadPickCount, "Road Food pick", "Road Food picks")
        return parts.joined(separator: " · ")
    }

    /// True for the LIFT web app's address with no plan fragment. The web app
    /// removes the fragment from the address bar as soon as it has read it
    /// (`history.replaceState` in lift/app.js, exactly as the Coach web app
    /// does with a log link), so a plan link opened in Safari and then shared
    /// from there arrives like this -- worth its own explanation, since the
    /// lifter did share "the link".
    static func isLiftPageWithoutPlan(_ text: String) -> Bool {
        fragment(in: text) == nil
            && liftPagePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// True for a `/coach/#1z...` link -- the log link this phone sends *to* a
    /// coach, which is not a plan and never opens here. Worth saying plainly:
    /// it is the one wrong link a lifter is most likely to have to hand.
    static func isCoachLogLink(_ text: String) -> Bool {
        coachLinkPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The URL that opens LIFT and shows the plan in `fragment`.
    static func openURL(for fragment: String) -> URL? {
        URL(string: "\(urlScheme)://\(urlHost)#\(fragment)")
    }

    /// True when this URL was aimed at LIFT: its own scheme, or the plan page
    /// on the real host (which only arrives through Universal Links, and only
    /// on a paid team -- see the Makefile). Anything else opened LIFT by
    /// accident and is left alone rather than reported as a bad plan.
    static func isAddressedToLift(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == urlScheme { return true }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        let host = url.host()?.lowercased() ?? ""
        guard host == "dugcanlift.com" || host == "www.dugcanlift.com" else { return false }
        return url.path() == "/lift" || url.path().hasPrefix("/lift/")
    }

    // `(?i:...)` scopes case-insensitivity to the host and scheme: the codec
    // letter after `1` is case-sensitive, and `1Z` is not a codec. The
    // lookbehind stops `notdugcanlift.com`, or the real host appearing in
    // another site's path or userinfo, from counting as the real host.
    private static let linkPattern = try! NSRegularExpression(pattern:
        #"(?i:(?<![A-Za-z0-9./@-])(?:(?:https?://)?(?:www\.)?dugcanlift\.com/lift/?(?:index\.html)?|dugcanliftlift:(?://)?[^\s#]*))#(1[zu][A-Za-z0-9_-]+)"#)

    private static let liftPagePattern = try! NSRegularExpression(pattern:
        #"^\s*(?i:(?:https?://)?(?:www\.)?dugcanlift\.com/lift/?(?:index\.html)?)#?\s*$"#)

    private static let coachLinkPattern = try! NSRegularExpression(pattern:
        #"(?i:(?<![A-Za-z0-9./@-])(?:https?://)?(?:www\.)?dugcanlift\.com/coach/?(?:index\.html)?)#(1[zu][A-Za-z0-9_-]+)"#)

    private static func isBase64URLCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
    }
}
