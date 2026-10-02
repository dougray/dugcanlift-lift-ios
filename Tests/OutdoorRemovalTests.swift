import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// Deleting a recorded run: what goes, what must not, and the sentence asked
/// first.
///
/// The half that matters is Apple Health. LIFT writes an `HKWorkout` with its
/// route when a run finishes, and that workout is not LIFT's to delete —
/// these tests pin that the rule never touches it and that the confirmation
/// says so.
@MainActor
final class OutdoorRemovalTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        ModelContext(LiftStore.makeContainer(inMemory: true))
    }

    private let start = Date(timeIntervalSince1970: 1_757_000_000)

    @discardableResult
    private func makeActivity(_ type: OutdoorActivityType = .run,
                              dayOffset: Double = 0,
                              meters: Double = 5_000,
                              seconds: TimeInterval = 1_500,
                              points: Int = 3,
                              inHealth: Bool = false,
                              in context: ModelContext) -> OutdoorActivity {
        let startedAt = start.addingTimeInterval(dayOffset * 86_400)
        let activity = OutdoorActivity(activityType: type, startedAt: startedAt)
        activity.endedAt = startedAt.addingTimeInterval(seconds)
        activity.distanceMeters = meters
        activity.routePoints = (0..<points).map { index in
            RoutePoint(latitude: 37.77 + Double(index) / 1_000,
                       longitude: -122.42,
                       altitudeMeters: 10,
                       recordedAt: startedAt.addingTimeInterval(Double(index)),
                       horizontalAccuracyMeters: 5,
                       verticalAccuracyMeters: 5)
        }
        if inHealth { activity.healthKitUUID = UUID() }
        context.insert(activity)
        try? context.save()
        return activity
    }

    private func count(in context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<OutdoorActivity>())) ?? 0
    }

    // MARK: - What goes

    func testDeletingARunTakesTheRunAndItsRoute() throws {
        let context = try makeContext()
        let run = makeActivity(in: context)
        XCTAssertEqual(run.routePoints.count, 3)

        XCTAssertTrue(OutdoorRemoval.remove(run, in: context))

        XCTAssertEqual(count(in: context), 0)
        // The route is `routePointsData` on the row itself, so there is no
        // second store to check and nothing left to sweep -- which is the
        // whole reason this delete has no side-cars, unlike a routine's.
    }

    func testDeletingARunLeavesEveryOtherRunAlone() throws {
        let context = try makeContext()
        let first = makeActivity(dayOffset: 0, meters: 5_000, in: context)
        makeActivity(dayOffset: 1, meters: 6_000, in: context)
        makeActivity(.hike, dayOffset: 2, meters: 12_000, in: context)

        XCTAssertTrue(OutdoorRemoval.remove(first, in: context))

        let left = try context.fetch(FetchDescriptor<OutdoorActivity>(sortBy: [SortDescriptor(\.startedAt)]))
        XCTAssertEqual(left.map(\.distanceMeters), [6_000, 12_000])
    }

    // MARK: - What is worked out again

    /// Nothing stores a best, so nothing has to be swept: `OutdoorRecords`
    /// reads whatever is left. Deleting the farthest run makes the next one
    /// the farthest, with no bookkeeping anywhere.
    func testTheBestsAreWhateverIsLeftAfterwards() throws {
        let context = try makeContext()
        let far = makeActivity(dayOffset: 0, meters: 21_000, seconds: 7_200, in: context)
        makeActivity(dayOffset: 1, meters: 5_000, seconds: 1_500, in: context)

        let before = try XCTUnwrap(OutdoorRecords.bests(in: context.fetch(FetchDescriptor<OutdoorActivity>())).first)
        XCTAssertEqual(before.longestDistanceMeters, 21_000)

        XCTAssertTrue(OutdoorRemoval.remove(far, in: context))

        let after = try XCTUnwrap(OutdoorRecords.bests(in: context.fetch(FetchDescriptor<OutdoorActivity>())).first)
        XCTAssertEqual(after.longestDistanceMeters, 5_000)
        XCTAssertEqual(after.count, 1)
    }

    /// The last run deleted leaves no bests at all rather than bests of zero.
    func testDeletingTheOnlyRunLeavesNoBests() throws {
        let context = try makeContext()
        let only = makeActivity(in: context)

        XCTAssertTrue(OutdoorRemoval.remove(only, in: context))

        XCTAssertTrue(try OutdoorRecords.bests(in: context.fetch(FetchDescriptor<OutdoorActivity>())).isEmpty)
        XCTAssertNil(try OutdoorRecords.lastRoute(in: context.fetch(FetchDescriptor<OutdoorActivity>())))
    }

    // MARK: - Apple Health

    /// `healthKitUUID` is the one thing on the row that points outside the
    /// app. Removing the row must not be read as permission to remove the
    /// workout it names.
    func testAnActivityInHealthIsSummarisedAsSuch() throws {
        let context = try makeContext()
        let exported = makeActivity(inHealth: true, in: context)
        let notExported = makeActivity(dayOffset: 1, meters: 1_000, in: context)

        XCTAssertTrue(OutdoorRemoval.summary(for: exported, in: context).isInHealth)
        XCTAssertFalse(OutdoorRemoval.summary(for: notExported, in: context).isInHealth)
    }

    func testTheConfirmationSaysTheHealthWorkoutStays() throws {
        let sentence = OutdoorRemoval.warning(
            OutdoorRemoval.Summary(isInHealth: true, holdsABest: false, typeName: "Run"))
        XCTAssertEqual(sentence,
                       "Its route goes with it. "
                       + "The workout LIFT saved to Apple Health stays there. "
                       + "Delete it in the Health app if you want it gone.")
    }

    /// A clause about nothing is left out entirely, the distinction
    /// `RoutineRemoval`'s confirmation makes: a run that was never exported
    /// gets no sentence about Health at all, rather than one saying there is
    /// nothing there.
    func testAnActivityNeverExportedIsToldNothingAboutHealth() throws {
        let sentence = OutdoorRemoval.warning(
            OutdoorRemoval.Summary(isInHealth: false, holdsABest: false, typeName: "Walk"))
        XCTAssertEqual(sentence, "Its route goes with it.")
        XCTAssertFalse(sentence.contains("Health"))
    }

    // MARK: - Bests in the sentence

    func testAConfirmationNamesABestThisActivityHolds() throws {
        let context = try makeContext()
        let far = makeActivity(dayOffset: 0, meters: 21_000, seconds: 7_200, in: context)
        makeActivity(dayOffset: 1, meters: 5_000, seconds: 1_500, in: context)

        let summary = OutdoorRemoval.summary(for: far, in: context)
        XCTAssertTrue(summary.holdsABest)
        XCTAssertEqual(OutdoorRemoval.warning(summary),
                       "Its route goes with it. "
                       + "It holds one of your run bests, so that figure is worked out again without it.")
    }

    func testAnOrdinaryRunIsNotClaimedToHoldABest() throws {
        let context = try makeContext()
        makeActivity(dayOffset: 0, meters: 21_000, seconds: 7_200, in: context)
        let middling = makeActivity(dayOffset: 1, meters: 5_000, seconds: 2_000, in: context)

        XCTAssertFalse(OutdoorRemoval.summary(for: middling, in: context).holdsABest)
    }

    /// Bests are asked of `OutdoorRecords`, so its rule that a pace under a
    /// kilometre is GPS noise holds here too: a 300 m sprint is nobody's
    /// fastest pace, however fast the arithmetic says it was.
    func testAShortSprintDoesNotCountAsAPaceBest() throws {
        let context = try makeContext()
        makeActivity(dayOffset: 0, meters: 21_000, seconds: 7_200, in: context)
        let sprint = makeActivity(dayOffset: 1, meters: 300, seconds: 60, in: context)

        XCTAssertFalse(OutdoorRemoval.summary(for: sprint, in: context).holdsABest)
    }

    /// A type with one recording holds every best it has, which is worth
    /// saying before it goes.
    func testTheOnlyRunOfItsTypeHoldsItsBests() throws {
        let context = try makeContext()
        let hike = makeActivity(.hike, meters: 12_000, seconds: 10_800, in: context)

        let summary = OutdoorRemoval.summary(for: hike, in: context)
        XCTAssertTrue(summary.holdsABest)
        XCTAssertEqual(summary.typeName, "Hike")
        XCTAssertTrue(OutdoorRemoval.warning(summary).contains("one of your hike bests"))
    }
}
