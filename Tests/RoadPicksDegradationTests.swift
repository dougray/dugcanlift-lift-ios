import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// Old-decoder degradation: how a LIFT iOS build that has never heard of a
/// coach's road picks reads a plan that carries them.
///
/// `Fixtures/web-plan-road-picks.txt` is a plan link Coach web's own encoder
/// wrote (dugcanlift-coach, `coach/fixtures/`, the same bytes -- md5
/// 5c2f783c291f9c757e86a75a014510e6). It carries one recipe, two meals, one
/// workout, one booked session and six ids in `rf`, one of them deliberately
/// not in anyone's `road-food.json`. PLAN-FORMAT.md "Road picks" promises the
/// key is purely additive: `v` stays 1, and a build that has never heard of
/// `rf` takes the meals and the training in exactly as before and simply does
/// not see it. Never regenerate the fixture from Swift; its whole value is
/// that a different implementation wrote it.
///
/// **This test was written and run before anything on this branch changed**,
/// against `origin/main` (8b2c6a5) -- `PlanLinkCodec.decode` from LiftKit
/// 1.10.0 and `PlanImporter.accept` as main had them. It passed unmodified:
/// one recipe, two meals, one routine, one session, and not one pick id
/// anywhere in the store or in `UserDefaults`. Those assertions are that run.
///
/// The "old decoder" it names is still the live one: `PlanPayload` is
/// LiftKit's, the kit is pinned to an exact tag, and this branch does not
/// change it -- `rf` is read app-side (`RoadPickLink`) precisely so the kit
/// stays where it is. So nothing is frozen in a copy here; the type that
/// ignores the key is the same type the app compiles against. What this file
/// must never gain is a call to anything on this branch that reads `rf`.
final class RoadPicksDegradationTests: XCTestCase {

    static func fixtureFragment() throws -> String {
        let url = try XCTUnwrap(Bundle(for: RoadPicksDegradationTests.self)
            .url(forResource: "web-plan-road-picks", withExtension: "txt"),
            "web-plan-road-picks.txt missing from the test bundle")
        let link = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = try XCTUnwrap(link.firstIndex(of: "#"))
        return String(link[link.index(after: hash)...])
    }

    /// The fixture's JSON, read here rather than through any of this branch's
    /// code: the point is to show what the key looks like to a decoder that
    /// has no field for it.
    static func fixtureJSON() throws -> [String: Any] {
        let fragment = try fixtureFragment()
        let body = String(fragment.dropFirst(2))
        let raw = try XCTUnwrap(CompactEncoding.base64URLDecode(body))
        let json = try XCTUnwrap(CompactEncoding.inflateRaw(raw))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    }

    func testTheFixtureReallyCarriesPicksAndDoesNotBumpTheVersion() throws {
        let json = try Self.fixtureJSON()
        XCTAssertEqual(json["v"] as? Int, 1, "purely additive: no version bump")
        XCTAssertEqual(json["t"] as? String, "plan")
        let rf = try XCTUnwrap(json["rf"] as? [String])
        XCTAssertEqual(rf, [
            "wendys-large-chili",
            "wendys-grilled-chicken-ranch-wrap",
            "chickfila-8-ct-grilled-nuggets",
            "chickfila-grilled-filet",
            "snack-jack-links-original-beef-jerky",
            "wendys-item-withdrawn-2019",
        ])
    }

    @MainActor
    func testOldDecoderTakesInEverythingButThePicks() throws {
        let payload = try PlanLinkCodec.decode(fragment: Self.fixtureFragment(),
                                               expectedLifterID: "a1b2c3d4")
        XCTAssertEqual(payload.v, 1, "no version bump, so an old build does not refuse the link")
        XCTAssertEqual(payload.n, "Doug")

        let context = ModelContext(LiftStore.makeContainer(inMemory: true))
        let suite = "road-picks-degradation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try PlanImporter.accept(payload, hash: PlanImporter.hash(of: payload), in: context,
                                defaults: defaults)

        // The meals half, exactly as main imported it.
        let recipes = try context.fetch(FetchDescriptor<Recipe>())
        XCTAssertEqual(recipes.map(\.name), ["Beef Chilli"])
        XCTAssertEqual(recipes[0].servings, 4)
        XCTAssertEqual(recipes[0].nutritionPerServing?.calories, 438)
        XCTAssertEqual(recipes[0].nutritionPerServing?.proteinG, 36)
        XCTAssertEqual(recipes[0].nutritionPerServing?.carbsG, 31)
        XCTAssertEqual(recipes[0].nutritionPerServing?.fatG, 19)
        XCTAssertEqual(recipes[0].nutritionPerServing?.fiberG, 9)
        XCTAssertEqual(recipes[0].nutritionPerServing?.sodiumMg, 620, "ux still rides in")
        XCTAssertEqual((recipes[0].ingredients ?? []).count, 3)

        let meals = try context.fetch(FetchDescriptor<PlannedMeal>())
            .sorted { $0.dayKey < $1.dayKey }
        XCTAssertEqual(meals.map(\.dayKey), ["2026-09-28", "2026-09-29"])
        XCTAssertEqual(meals.map(\.mealType), [.dinner, .lunch])
        XCTAssertEqual(meals.map(\.servings), [2, 1])

        // The training half, likewise.
        let routines = try context.fetch(FetchDescriptor<Routine>())
        XCTAssertEqual(routines.map(\.name), ["Lower A"])
        XCTAssertEqual(routines[0].orderedExercises.map(\.name),
                       ["Back Squat", "Bulgarian Split Squat"])
        XCTAssertEqual(routines[0].orderedExercises.map { $0.orderedSets.count }, [3, 2])
        let sessions = try context.fetch(FetchDescriptor<ScheduledSession>())
        XCTAssertEqual(sessions.map(\.dayKey), ["2026-09-28"])

        // And not one pick id anywhere: the key is simply unread.
        let ids = try XCTUnwrap(try Self.fixtureJSON()["rf"] as? [String])
        let stored = [
            try context.fetch(FetchDescriptor<Recipe>()).map(\.name).joined(separator: "|"),
            try context.fetch(FetchDescriptor<Routine>()).map(\.name).joined(separator: "|"),
            try context.fetch(FetchDescriptor<ScheduledSession>()).map(\.routineName)
                .joined(separator: "|"),
            String(describing: defaults.dictionaryRepresentation()),
        ].joined(separator: "\n")
        for id in ids {
            XCTAssertFalse(stored.contains(id), "\(id) reached storage")
        }
        XCTAssertFalse(stored.contains("wendys"))
        XCTAssertFalse(stored.contains("chickfila"))
    }
}
