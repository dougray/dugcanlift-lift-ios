import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// The three doors a coach's plan comes through on a free-team build: the
/// `dugcanliftlift://` scheme, Paste a Plan Link, and the share extension's
/// queue. All three ask `PlanLinkIntake`, so these cases pin one rule rather
/// than three.
///
/// A case-for-case port of Coach iOS's `ShareLinkExtractorTests`, with the
/// hosts swapped (`/lift/` here, `/coach/` there) and the plan-specific cases
/// added. The two extractors are one rule in two repositories; change one,
/// change both.
final class PlanLinkExtractorTests: XCTestCase {

    private let link = "https://www.dugcanlift.com/lift/#1zABC-def_123"

    // MARK: Where the link is found

    func testAFullLinkReducesToItsFragment() {
        XCTAssertEqual(PlanLinkExtractor.fragment(in: link), "1zABC-def_123")
    }

    func testTheUncompressedCodecIsAccepted() {
        XCTAssertEqual(PlanLinkExtractor.fragment(in: "https://www.dugcanlift.com/lift/#1uXYZ"), "1uXYZ")
    }

    func testHostVariantsAreAccepted() {
        for text in ["http://dugcanlift.com/lift/#1zABC",
                     "HTTPS://WWW.DUGCANLIFT.COM/lift/#1zABC",
                     "www.dugcanlift.com/lift/#1zABC",
                     "https://www.dugcanlift.com/lift#1zABC",
                     "https://www.dugcanlift.com/lift/index.html#1zABC"] {
            XCTAssertEqual(PlanLinkExtractor.fragment(in: text), "1zABC", text)
        }
    }

    func testTextAroundTheLinkIsIgnored() {
        let message = """
        Here's week #3, same as we talked about: \(link)
        Hit me up if the squat weight looks off.
        """
        XCTAssertEqual(PlanLinkExtractor.fragment(in: message), "1zABC-def_123")
    }

    func testTrailingPunctuationAndMailBracketsAreDropped() {
        XCTAssertEqual(PlanLinkExtractor.fragment(in: "<\(link)>"), "1zABC-def_123")
        XCTAssertEqual(PlanLinkExtractor.fragment(in: "Your plan: \(link)."), "1zABC-def_123")
        XCTAssertEqual(PlanLinkExtractor.fragment(in: "(\(link))"), "1zABC-def_123")
    }

    func testTheFirstLinkWinsWhenAThreadQuotesAnother() {
        let text = "New: https://www.dugcanlift.com/lift/#1zNEW\n> Old: https://www.dugcanlift.com/lift/#1zOLD"
        XCTAssertEqual(PlanLinkExtractor.fragment(in: text), "1zNEW")
    }

    func testLiftsOwnURLSchemeIsAccepted() {
        XCTAssertEqual(PlanLinkExtractor.fragment(in: "dugcanliftlift://plan#1zABC"), "1zABC")
        XCTAssertEqual(PlanLinkExtractor.openURL(for: "1zABC")?.absoluteString, "dugcanliftlift://plan#1zABC")
    }

    func testABareFragmentIsAccepted() {
        XCTAssertEqual(PlanLinkExtractor.fragment(in: "  1zABC\n"), "1zABC")
        XCTAssertEqual(PlanLinkExtractor.fragment(in: "#1zABC sent from Coach"), "1zABC")
    }

    // MARK: What is refused

    func testAnotherSitesURLIsRefusedEvenWithALiftShapedFragment() {
        XCTAssertNil(PlanLinkExtractor.fragment(in: "https://example.com/lift/#1zABC"))
        XCTAssertNil(PlanLinkExtractor.fragment(in: "https://notdugcanlift.com/lift/#1zABC"))
        XCTAssertNil(PlanLinkExtractor.fragment(in: "https://dugcanlift.com.evil.example/lift/#1zABC"))
        XCTAssertNil(PlanLinkExtractor.fragment(in: "https://evil.example/www.dugcanlift.com/lift/#1zABC"))
        XCTAssertNil(PlanLinkExtractor.fragment(in: "https://evil.example@dugcanlift.com/lift/#1zABC"))
    }

    /// The mirror of Coach's "other dugcanlift.com pages are refused": the
    /// coach app's log link is a different link travelling the other way, and
    /// it decodes to JSON shaped enough like a plan that the wrong door
    /// opening it would be a real confusion, not a cosmetic one.
    func testTheCoachLogLinkIsRefusedHere() {
        XCTAssertNil(PlanLinkExtractor.fragment(in: "https://www.dugcanlift.com/coach/#1zABC"))
        XCTAssertNil(PlanLinkExtractor.fragment(in: "dugcanliftcoach://import#1zABC"))
        XCTAssertNil(PlanLinkExtractor.fragment(in: "https://www.dugcanlift.com/lift/"))
        XCTAssertTrue(PlanLinkExtractor.isCoachLogLink("Sent you this: https://www.dugcanlift.com/coach/#1zABC"))
        XCTAssertFalse(PlanLinkExtractor.isCoachLogLink(link))
    }

    func testTextWithNoLinkIsRefused() {
        for text in ["", "   ", "#", "1z", "Good session today!", "1Zabc", "2zABC", "week #1zABC"] {
            XCTAssertNil(PlanLinkExtractor.fragment(in: text), text)
        }
    }

    func testTheLiftWebPageWithItsPlanStrippedIsRecognised() {
        XCTAssertTrue(PlanLinkExtractor.isLiftPageWithoutPlan("https://www.dugcanlift.com/lift/"))
        XCTAssertTrue(PlanLinkExtractor.isLiftPageWithoutPlan("https://www.dugcanlift.com/lift"))
        XCTAssertFalse(PlanLinkExtractor.isLiftPageWithoutPlan(link))
        XCTAssertFalse(PlanLinkExtractor.isLiftPageWithoutPlan("https://www.dugcanlift.com/coach/"))
        XCTAssertFalse(PlanLinkExtractor.isLiftPageWithoutPlan("Good session!"))
    }

    // MARK: Which URLs LIFT answers for at all

    func testOnlyLiftsOwnURLsAreAddressedToIt() {
        for text in ["dugcanliftlift://plan#1zABC",
                     "https://www.dugcanlift.com/lift/#1zABC",
                     "https://dugcanlift.com/lift",
                     "http://www.dugcanlift.com/lift/index.html#1zABC"] {
            XCTAssertTrue(PlanLinkExtractor.isAddressedToLift(URL(string: text)!), text)
        }
        for text in ["https://www.dugcanlift.com/coach/#1zABC",
                     "https://www.dugcanlift.com/",
                     "https://www.dugcanlift.com/lifting/#1zABC",
                     "https://example.com/lift/#1zABC",
                     "dugcanliftcoach://import#1zABC"] {
            XCTAssertFalse(PlanLinkExtractor.isAddressedToLift(URL(string: text)!), text)
        }
    }

    // MARK: A real link

    /// `Fixtures/web-plan-per-side.txt` is a plan link Coach web's own encoder
    /// wrote, addressed to lifter `a1b2c3d4`. Never regenerate it from Swift.
    static func fixtureLink() throws -> String {
        let url = try XCTUnwrap(Bundle(for: PlanLinkExtractorTests.self)
            .url(forResource: "web-plan-per-side", withExtension: "txt"),
            "web-plan-per-side.txt missing from the test bundle")
        return try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let fixtureLifterID = "a1b2c3d4"

    func testARealLinkInsideAMessageDecodesAndSummarises() throws {
        let text = "Here's next week 💪\n\(try Self.fixtureLink())\nSee you Monday"
        let payload = try PlanLinkExtractor.payload(in: text, expectedLifterID: Self.fixtureLifterID)
        XCTAssertEqual(payload.n, "Doug")
        XCTAssertEqual(PlanLinkExtractor.summary(of: payload),
                       "Plan from Doug · 1 workout · 1 scheduled day")
    }

    func testTheURLSchemeCarriesARealLink() throws {
        let fragment = try XCTUnwrap(PlanLinkExtractor.fragment(in: try Self.fixtureLink()))
        let url = try XCTUnwrap(PlanLinkExtractor.openURL(for: fragment))
        let payload = try PlanLinkExtractor.payload(in: url.absoluteString,
                                                    expectedLifterID: Self.fixtureLifterID)
        XCTAssertEqual(payload.w?.first?.n, "Per-side A")
    }

    func testSummaryNamesEveryPartAPlanCarries() {
        let payload = PlanPayload(
            v: 1, t: "plan", l: "a1b2c3d4", n: "  ",
            r: [PlanRecipe(n: "Chilli", s: 4, u: nil, i: nil, t: nil, ux: nil),
                PlanRecipe(n: "Oats", s: 1, u: nil, i: nil, t: nil, ux: nil)],
            m: [PlanMeal(d: "2026-08-26", s: 2, x: 0, q: 1)],
            w: nil, k: nil)
        // A coach with no name is "your coach", never an empty gap, and a
        // count of zero is left out entirely rather than shown as "0 workouts".
        XCTAssertEqual(PlanLinkExtractor.summary(of: payload),
                       "Plan from your coach · 2 recipes · 1 planned meal")
    }
}

/// What each door does with a link, decided in one place so the three cannot
/// drift apart.
final class PlanLinkIntakeTests: XCTestCase {

    private let lifterID = PlanLinkExtractorTests.fixtureLifterID

    private func fixtureFragment() throws -> String {
        try XCTUnwrap(PlanLinkExtractor.fragment(in: try PlanLinkExtractorTests.fixtureLink()))
    }

    // MARK: The custom scheme

    func testAValidPlanURLOpensThePlan() throws {
        let url = try XCTUnwrap(PlanLinkExtractor.openURL(for: try fixtureFragment()))
        guard case .plan(let incoming) = PlanLinkIntake.open(url, expectedLifterID: lifterID) else {
            return XCTFail("a real plan link should open")
        }
        XCTAssertEqual(incoming.payload.n, "Doug")
    }

    func testJunkInTheSchemeIsRefusedRatherThanIgnored() {
        let junk = URL(string: "dugcanliftlift://plan#notaplan")!
        XCTAssertEqual(PlanLinkIntake.open(junk, expectedLifterID: lifterID),
                       .refused(.notAPlanLink))

        let shaped = URL(string: "dugcanliftlift://plan#1zNotReallyDeflate")!
        XCTAssertEqual(PlanLinkIntake.open(shaped, expectedLifterID: lifterID),
                       .refused(.link(.corruptPayload)))
    }

    /// The one that used to be a silent no-op with a confusing shape: a
    /// coach's log link arriving at LIFT. It is not ours and not an error, so
    /// nothing is said -- exactly what `handleIncomingURL` did before, and
    /// what must keep happening once a paid team makes Universal Links live
    /// across the whole www.dugcanlift.com host.
    func testACoachLogLinkArrivingAtLiftIsIgnored() throws {
        let coachLink = URL(string: "https://www.dugcanlift.com/coach/#1zABC")!
        XCTAssertEqual(PlanLinkIntake.open(coachLink, expectedLifterID: lifterID), .ignored)

        let elsewhere = URL(string: "https://example.com/#1zABC")!
        XCTAssertEqual(PlanLinkIntake.open(elsewhere, expectedLifterID: lifterID), .ignored)
    }

    func testAUniversalLinkStillOpensAPlanForTheDayThereIsAPaidTeam() throws {
        let url = try XCTUnwrap(URL(string: "https://www.dugcanlift.com/lift/#\(try fixtureFragment())"))
        guard case .plan = PlanLinkIntake.open(url, expectedLifterID: lifterID) else {
            return XCTFail("the Universal Link path must keep working")
        }
    }

    func testTheLiftPageWithItsPlanAlreadyReadSaysSo() {
        let url = URL(string: "https://www.dugcanlift.com/lift/")!
        XCTAssertEqual(PlanLinkIntake.open(url, expectedLifterID: lifterID),
                       .refused(.pageWithoutPlan))
    }

    // MARK: Pasted text and queued fragments

    func testABareFragmentPastedOnItsOwnOpensThePlan() throws {
        guard case .plan = PlanLinkIntake.read(try fixtureFragment(), expectedLifterID: lifterID) else {
            return XCTFail("a bare fragment is what the share extension queues")
        }
    }

    func testAPlanAddressedToAnotherPhoneIsRefusedByName() throws {
        XCTAssertEqual(PlanLinkIntake.read(try fixtureFragment(), expectedLifterID: "ffffffff"),
                       .refused(.link(.notAddressedToThisDevice)))
    }

    func testPastingTheWrongThingsEachGetTheirOwnReason() {
        XCTAssertEqual(PlanLinkIntake.read("Good session today!", expectedLifterID: lifterID),
                       .refused(.notAPlanLink))
        XCTAssertEqual(PlanLinkIntake.read("https://example.com/lift/#1zABC", expectedLifterID: lifterID),
                       .refused(.notAPlanLink))
        XCTAssertEqual(PlanLinkIntake.read("https://www.dugcanlift.com/coach/#1zABC", expectedLifterID: lifterID),
                       .refused(.ownLogLink))
        XCTAssertEqual(PlanLinkIntake.read("https://www.dugcanlift.com/lift/", expectedLifterID: lifterID),
                       .refused(.pageWithoutPlan))
    }

    func testEveryRefusalSaysSomethingAndNoneOfThemSaysNil() {
        let refusals: [PlanLinkIntake.Refusal] = [
            .notAPlanLink, .ownLogLink, .pageWithoutPlan,
            .link(.notAddressedToThisDevice), .link(.corruptPayload),
            .link(.malformedFragment), .link(.unsupportedVersion("2")),
            .link(.unsupportedCodec("q")),
        ]
        for refusal in refusals {
            XCTAssertFalse(refusal.message.isEmpty, "\(refusal)")
        }
        // The two that a lifter is most likely to hit must not read the same:
        // "not a plan link" and "that's your own log link" are different
        // mistakes with different fixes.
        XCTAssertNotEqual(PlanLinkIntake.Refusal.notAPlanLink.message,
                          PlanLinkIntake.Refusal.ownLogLink.message)
    }

    /// The whole point of the branch: a link the fixture's coach sent reaches
    /// the same `PlanImporter` an accepted Universal Link always did, with the
    /// same routine on the other side.
    @MainActor
    func testAPastedLinkImportsThroughTheOrdinaryPlanPath() throws {
        guard case .plan(let incoming) = PlanLinkIntake.read(
            "From Coach: \(try PlanLinkExtractorTests.fixtureLink())", expectedLifterID: lifterID)
        else { return XCTFail("the fixture link should decode") }

        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        let suite = "plan-link-entry-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        try PlanImporter.accept(incoming, hash: PlanImporter.hash(of: incoming.payload),
                                in: context, defaults: defaults)
        let routines = try context.fetch(FetchDescriptor<Routine>())
        XCTAssertEqual(routines.map(\.name), ["Per-side A"])
    }
}

/// The share extension's hand-off. The extension writes here and never touches
/// the store; the app drains it whenever the scene becomes active.
final class PendingPlanLinksTests: XCTestCase {

    private var suiteName: String!
    private var inbox: PendingPlanLinks!

    override func setUp() {
        suiteName = "PendingPlanLinksTests-\(UUID().uuidString)"
        inbox = PendingPlanLinks(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func testTakeAllReturnsOldestFirstAndEmptiesTheQueue() {
        inbox.add("1zA")
        inbox.add("1zB")
        XCTAssertEqual(inbox.takeAll(), ["1zA", "1zB"])
        XCTAssertEqual(inbox.takeAll(), [])
    }

    func testTheSameLinkSharedTwiceIsQueuedOnceAtItsNewestPosition() {
        inbox.add("1zA")
        inbox.add("1zB")
        inbox.add("1zA")
        XCTAssertEqual(inbox.pending, ["1zB", "1zA"])
    }

    func testTheQueueIsBoundedAndDropsTheOldest() {
        for i in 0..<(PendingPlanLinks.limit + 5) { inbox.add("1z\(i)") }
        XCTAssertEqual(inbox.pending.count, PendingPlanLinks.limit)
        XCTAssertEqual(inbox.pending.first, "1z5")
    }

    /// An extension has its own `UserDefaults.standard`, so the lifter's id
    /// only reaches it through the group. Absent until the app has run once,
    /// which the extension says in words rather than guessing.
    func testTheLifterIDIsAbsentUntilTheAppMirrorsIt() {
        XCTAssertNil(inbox.lifterID)
        inbox.mirror(lifterID: "a1b2c3d4")
        XCTAssertEqual(inbox.lifterID, "a1b2c3d4")
        // Generated once and never regenerated, so an empty id must not wipe
        // the real one a previous launch wrote.
        inbox.mirror(lifterID: "")
        XCTAssertEqual(inbox.lifterID, "a1b2c3d4")
    }

    /// What `LiftApp.drainSharedPlans` does, without a scene: everything the
    /// extension queued goes through the same intake a paste does, and the
    /// queue is empty afterwards so a plan is never offered twice.
    func testADrainedQueueGoesThroughTheSameIntakeAndDoesNotRepeat() throws {
        let fragment = try XCTUnwrap(PlanLinkExtractor.fragment(in: try PlanLinkExtractorTests.fixtureLink()))
        inbox.add("1zNotReallyDeflate")
        inbox.add(fragment)

        let outcomes = inbox.takeAll().map {
            PlanLinkIntake.read($0, expectedLifterID: PlanLinkExtractorTests.fixtureLifterID)
        }
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(outcomes.first, .refused(.link(.corruptPayload)))
        guard case .plan(let incoming) = outcomes.last else { return XCTFail("the real plan should survive the queue") }
        XCTAssertEqual(incoming.payload.n, "Doug")
        XCTAssertEqual(inbox.takeAll(), [])
    }
}
