import XCTest
import SwiftData
import CryptoKit
import LiftCore
@testable import Lift

/// Taking a coach's road picks in: `rf` off the link, through the importer,
/// into storage -- and what happens to everything else while that is going on.
///
/// The fixture is `Fixtures/web-plan-road-picks.txt`, the link Coach web's own
/// encoder wrote. `RoadPicksDegradationTests` is the other half of it: what a
/// build without any of this makes of the same bytes.
final class PlanRoadPicksTests: XCTestCase {

    private let lifterID = "a1b2c3d4"

    private func fixtureFragment() throws -> String {
        try RoadPicksDegradationTests.fixtureFragment()
    }

    private func store(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "plan-road-picks-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("no suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    // MARK: - Off the link

    func testTheFragmentsPicksAreReadInTheCoachsOrder() throws {
        XCTAssertEqual(RoadPickLink.ids(inFragment: try fixtureFragment()), [
            "wendys-large-chili",
            "wendys-grilled-chicken-ranch-wrap",
            "chickfila-8-ct-grilled-nuggets",
            "chickfila-grilled-filet",
            "snack-jack-links-original-beef-jerky",
            "wendys-item-withdrawn-2019",
        ])
    }

    func testAPlanWithoutTheKeyReadsAsNoPicksRatherThanFailing() throws {
        // web-plan-per-side.txt is Coach web's own encoder again, from before
        // road picks existed: no `rf` at all.
        let url = try XCTUnwrap(Bundle(for: PlanRoadPicksTests.self)
            .url(forResource: "web-plan-per-side", withExtension: "txt"))
        let link = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fragment = String(link[link.index(after: try XCTUnwrap(link.firstIndex(of: "#")))...])
        XCTAssertEqual(RoadPickLink.ids(inFragment: fragment), [])
    }

    func testJunkIsNoPicksAndNeverAThrow() {
        for junk in ["", "1", "1z", "1z!!!!", "9z" + "AAAA", "1qAAAA", "nonsense"] {
            XCTAssertEqual(RoadPickLink.ids(inFragment: junk), [], junk)
        }
        // The key present but not a list of strings: the entries that are not
        // strings cost themselves, not the plan.
        XCTAssertEqual(RoadPickLink.ids(inJSON: Data(#"{"rf":["a",7,null,"a"," b "]}"#.utf8)),
                       ["a", "b"])
        XCTAssertEqual(RoadPickLink.ids(inJSON: Data(#"{"rf":"wendys-large-chili"}"#.utf8)), [],
                       "a bare string is not a list")
        XCTAssertEqual(RoadPickLink.ids(inJSON: Data(#"{"v":1}"#.utf8)), [])
    }

    func testTheIntakeHandsBothHalvesOn() throws {
        let outcome = PlanLinkIntake.read("Here you go: https://www.dugcanlift.com/lift/#"
                                          + (try fixtureFragment()), expectedLifterID: lifterID)
        guard case .plan(let incoming) = outcome else { return XCTFail("the fixture should open") }
        XCTAssertEqual(incoming.payload.n, "Doug")
        XCTAssertEqual(incoming.roadPickIDs.count, 6)
    }

    // MARK: - Into storage

    @MainActor
    func testTheRoundTripFromLinkToStoredPicks() throws {
        let outcome = PlanLinkIntake.read(try fixtureFragment(), expectedLifterID: lifterID)
        guard case .plan(let incoming) = outcome else { return XCTFail("the fixture should open") }

        try store { defaults in
            let context = ModelContext(LiftStore.makeContainer(inMemory: true))
            try PlanImporter.accept(incoming,
                                    hash: PlanImporter.hash(of: incoming.payload,
                                                            roadPickIDs: incoming.roadPickIDs),
                                    in: context, defaults: defaults)

            let picks = try XCTUnwrap(RoadPicks.load(from: defaults))
            XCTAssertEqual(picks.ids, incoming.roadPickIDs, "the list as sent, in order")
            XCTAssertEqual(picks.from, "Doug")
            XCTAssertEqual(picks.label("picks"), "Doug’s picks")
            // The unknown id is kept, not filtered on arrival: a later release
            // that has the item again shows the pick rather than having thrown
            // it away. It is skipped where the list is drawn, and
            // `RoadPicksTests` pins that end.
            XCTAssertTrue(picks.ids.contains("wendys-item-withdrawn-2019"))

            // And the rest of the plan landed exactly as it does without picks.
            XCTAssertEqual(try context.fetch(FetchDescriptor<Recipe>()).map(\.name), ["Beef Chilli"])
            XCTAssertEqual(try context.fetch(FetchDescriptor<PlannedMeal>()).count, 2)
            XCTAssertEqual(try context.fetch(FetchDescriptor<Routine>()).map(\.name), ["Lower A"])
            XCTAssertEqual(try context.fetch(FetchDescriptor<ScheduledSession>()).count, 1)
        }
    }

    @MainActor
    func testAPicksOnlyPlanIsARealSend() throws {
        let payload = PlanPayload(v: 1, t: "plan", l: lifterID, n: "Doug",
                                  r: nil, m: nil, w: nil, k: nil)
        let incoming = PlanLinkIntake.IncomingPlan(payload: payload,
                                                   roadPickIDs: ["wendys-large-chili"])
        XCTAssertEqual(PlanImporter.summary(for: incoming).roadPickCount, 1)
        XCTAssertEqual(PlanLinkExtractor.summary(of: payload, roadPickCount: 1),
                       "Plan from Doug · 1 Road Food pick",
                       "a send that is only picks says so rather than naming nothing")
        XCTAssertEqual(PlanLinkExtractor.summary(of: payload, roadPickCount: 6),
                       "Plan from Doug · 6 Road Food picks")

        try store { defaults in
            let context = ModelContext(LiftStore.makeContainer(inMemory: true))
            try PlanImporter.accept(incoming,
                                    hash: PlanImporter.hash(of: payload,
                                                            roadPickIDs: incoming.roadPickIDs),
                                    in: context, defaults: defaults)
            XCTAssertEqual(RoadPicks.load(from: defaults)?.ids, ["wendys-large-chili"])
            XCTAssertTrue(try context.fetch(FetchDescriptor<Recipe>()).isEmpty)
            XCTAssertTrue(try context.fetch(FetchDescriptor<Routine>()).isEmpty)
        }
    }

    @MainActor
    func testASecondPlanWithNoPicksLeavesTheStoredOnesAlone() throws {
        try store { defaults in
            let context = ModelContext(LiftStore.makeContainer(inMemory: true))
            let first = PlanPayload(v: 1, t: "plan", l: lifterID, n: "Doug",
                                    r: nil, m: nil, w: nil, k: nil)
            try PlanImporter.accept(first, roadPickIDs: ["a", "b"],
                                    hash: PlanImporter.hash(of: first, roadPickIDs: ["a", "b"]),
                                    in: context, defaults: defaults)
            let second = PlanPayload(v: 1, t: "plan", l: lifterID, n: "Doug",
                                     r: nil, m: nil,
                                     w: [PlanWorkout(n: "Push", e: [])],
                                     k: nil)
            try PlanImporter.accept(second, hash: PlanImporter.hash(of: second),
                                    in: context, defaults: defaults)
            XCTAssertEqual(RoadPicks.load(from: defaults)?.ids, ["a", "b"],
                           "a plan with no rf is silent about picks, not a retraction")
        }
    }

    // MARK: - The hash

    /// `HashableMirror` as it stood on main, verbatim, before `rf` joined it
    /// (`origin/main` 8b2c6a5, `Sources/Shared/PlanImporter.swift`). The
    /// promise is that a plan carrying no picks hashes to exactly what it
    /// hashed to before road picks existed, so nothing already imported is
    /// offered again.
    private struct MainsHashableMirror: Encodable {
        let v: Int
        let t: String
        let l: String
        let n: String
        let r: [PlanRecipe]?
        let m: [PlanMeal]?
        let w: [PlanWorkout]?
        let k: [PlanSession]?

        init(of payload: PlanPayload) {
            v = payload.v; t = payload.t; l = payload.l; n = payload.n
            r = payload.r; m = payload.m; w = payload.w; k = payload.k
        }
    }

    private func mainsHash(of payload: PlanPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(MainsHashableMirror(of: payload)))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func testAPlanWithNoPicksHashesExactlyAsItDidBeforeRoadPicks() throws {
        let payload = try PlanLinkCodec.decode(fragment: try fixtureFragment(),
                                               expectedLifterID: lifterID)
        XCTAssertEqual(try PlanImporter.hash(of: payload), try mainsHash(of: payload))
        // Recorded by running main's own `PlanImporter.hash` against this
        // fixture before anything on this branch changed.
        XCTAssertEqual(try PlanImporter.hash(of: payload),
                       "8e9a98502583a30ded4db901df75cf440c3a5ae5d54291b6d4b52a139495a425")
        XCTAssertEqual(try PlanImporter.hash(of: payload, roadPickIDs: []),
                       try mainsHash(of: payload), "an empty list writes no key at all")
    }

    func testPicksAreInTheHash() throws {
        let payload = try PlanLinkCodec.decode(fragment: try fixtureFragment(),
                                               expectedLifterID: lifterID)
        let withPicks = try PlanImporter.hash(of: payload,
                                              roadPickIDs: RoadPickLink.ids(inFragment: try fixtureFragment()))
        XCTAssertNotEqual(withPicks, try PlanImporter.hash(of: payload))
        // Or a coach resending the same week with a different answer about the
        // road would find the second link refused as already imported, and
        // their new picks silently lost.
        XCTAssertNotEqual(try PlanImporter.hash(of: payload, roadPickIDs: ["a"]),
                          try PlanImporter.hash(of: payload, roadPickIDs: ["b"]))
    }
}
