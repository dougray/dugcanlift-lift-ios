import Foundation
import LiftCore

/// What LIFT does with a link that arrives from outside it, and what it says
/// when it will not open one.
///
/// A value type with no view in it, for the reason `LiftProgression` is one: a
/// rule living in a view's `@State` cannot be tested, and this one decides
/// whether a coach's plan reaches someone or silently does nothing. `LiftApp`'s
/// `onOpenURL`, the queue drained when the app becomes active, and Paste a Plan
/// Link all read the answer from here, so the three doors accept and refuse
/// exactly the same text.
enum PlanLinkIntake {

    /// Why a link was not opened. Separate from `PlanLinkError` because two of
    /// these never reach the codec at all: the text had no plan fragment in it.
    enum Refusal: Equatable {
        /// Nothing in the text looks like a LIFT plan link.
        case notAPlanLink
        /// A `/coach/#1z...` log link -- the one this phone sends *to* a
        /// coach. It is the wrong direction, and it is the link a lifter is
        /// most likely to have to hand, so it gets its own sentence.
        case ownLogLink
        /// `www.dugcanlift.com/lift/` with the plan already stripped out of
        /// the address by the web app that read it.
        case pageWithoutPlan
        /// A real fragment the codec refused.
        case link(PlanLinkError)

        var message: String {
            switch self {
            case .notAPlanLink:
                // Verbatim, or SwiftUI turns the address into a tappable link.
                return "That doesn't look like a plan from a coach. Their link starts with www.dugcanlift.com/lift/#."
            case .ownLogLink:
                return "That's the log link you send to your coach, not a plan from them. A plan comes back as a www.dugcanlift.com/lift/# link."
            case .pageWithoutPlan:
                return "The plan isn't in this address. Opening the page reads the plan and removes it from the address. Share the link from the message or email it arrived in instead."
            case .link(.notAddressedToThisDevice):
                return "This plan isn't addressed to you. Ask your coach to send a new link for this phone."
            case .link:
                return "This plan link couldn't be read."
            }
        }
    }

    enum Outcome: Equatable {
        /// Not ours and not an error: some other link opened LIFT, or a bare
        /// `/lift/` address with nothing in it. Say nothing.
        case ignored
        case plan(IncomingPlan)
        case refused(Refusal)
    }

    /// A plan that opened, and the road picks riding in the same link.
    ///
    /// `rf` is not a field on LiftKit's `PlanPayload` -- it is read from the
    /// same fragment by `RoadPickLink`, app-side, so the pinned kit two
    /// shipped apps share does not move for a list of strings. Pairing them
    /// here is what keeps the pair together: every door ends at
    /// `PlanPreviewView` with both halves, and no call site can accept a plan
    /// and quietly drop its picks.
    struct IncomingPlan: Equatable {
        let payload: PlanPayload
        /// `rf`, normalised. Empty when the key was absent, which
        /// PLAN-FORMAT calls silence about picks rather than a retraction.
        let roadPickIDs: [String]
    }

    /// A URL handed to `onOpenURL`: LIFT's own `dugcanliftlift://plan#...`
    /// scheme, or -- on a paid team, where Associated Domains can be signed --
    /// a `https://www.dugcanlift.com/lift/#...` Universal Link.
    ///
    /// A URL that was never aimed at LIFT is `.ignored` rather than refused.
    /// The Associated Domains entitlement covers the whole `www.dugcanlift.com`
    /// host, not just `/lift/*`, so a coach's own `/coach/#...` log link lands
    /// here too once Universal Links are live; it is not an error, just not
    /// ours.
    static func open(_ url: URL, expectedLifterID: String) -> Outcome {
        guard PlanLinkExtractor.isAddressedToLift(url) else { return .ignored }
        guard let fragment = PlanLinkExtractor.fragment(in: url.absoluteString) else {
            // The custom scheme is only ever built by LIFT or typed on
            // purpose, so an empty one is worth reporting. A bare `/lift/`
            // page is what the web app leaves in Safari's address bar after
            // reading a plan, and tapping through to LIFT from it is common
            // enough that silence is wrong there too.
            return .refused(PlanLinkExtractor.isLiftPageWithoutPlan(url.absoluteString)
                            ? .pageWithoutPlan : .notAPlanLink)
        }
        return decode(fragment, expectedLifterID: expectedLifterID)
    }

    /// Text the lifter pasted, or a fragment the share extension queued.
    /// Unlike a URL, everything here was offered to LIFT on purpose, so there
    /// is no `.ignored`: text with no plan in it is refused with a reason.
    static func read(_ text: String, expectedLifterID: String) -> Outcome {
        guard let fragment = PlanLinkExtractor.fragment(in: text) else {
            if PlanLinkExtractor.isLiftPageWithoutPlan(text) { return .refused(.pageWithoutPlan) }
            if PlanLinkExtractor.isCoachLogLink(text) { return .refused(.ownLogLink) }
            return .refused(.notAPlanLink)
        }
        return decode(fragment, expectedLifterID: expectedLifterID)
    }

    private static func decode(_ fragment: String, expectedLifterID: String) -> Outcome {
        do {
            let payload = try PlanLinkCodec.decode(fragment: fragment,
                                                   expectedLifterID: expectedLifterID)
            // Only once the codec has accepted the link: `RoadPickLink` is
            // lenient by design and would answer "no picks" for anything,
            // including a fragment that is not a plan at all.
            return .plan(IncomingPlan(payload: payload,
                                      roadPickIDs: RoadPickLink.ids(inFragment: fragment)))
        } catch let error as PlanLinkError {
            return .refused(.link(error))
        } catch {
            return .refused(.link(.corruptPayload))
        }
    }
}
