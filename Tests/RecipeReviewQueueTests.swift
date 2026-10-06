import XCTest
@testable import Lift

/// The rules that decide when a recipe Safari handed over may open. The file
/// queue is emptied when it is drained, so a recipe this loses is gone.
final class RecipeReviewQueueTests: XCTestCase {

    private typealias Queue = RecipeReviewQueue<String>

    private func item(_ n: Int) -> PendingRecipeImports.Item {
        .init(block: #"{"@type":"Recipe","name":"Dish \#(n)"}"#, pageURL: "https://example.org/\(n)")
    }

    private func queue(_ count: Int) -> Queue {
        var q = Queue()
        q.enqueue((1...count).map(item))
        return q
    }

    func testOffersOneAtATimeInOrder() {
        var q = queue(3)
        XCTAssertEqual(q.next(canPresent: true)?.item, item(1))
        XCTAssertNil(q.next(canPresent: true), "one is under review")
        q.markAppeared()
        XCTAssertTrue(q.dismissed())
        XCTAssertEqual(q.next(canPresent: true)?.item, item(2))
        q.markAppeared()
        _ = q.dismissed()
        XCTAssertEqual(q.next(canPresent: true)?.item, item(3))
        q.markAppeared()
        _ = q.dismissed()
        XCTAssertNil(q.next(canPresent: true))
    }

    func testNothingIsOfferedWhileSomethingElseIsOnScreen() {
        var q = queue(1)
        XCTAssertNil(q.next(canPresent: false))
        XCTAssertEqual(q.waiting.count, 1, "it waits, it is not dropped")
        XCTAssertEqual(q.next(canPresent: true)?.item, item(1))
    }

    func testASheetThatNeverAppearedIsRetriedFirstOnNextActivation() {
        var q = queue(2)
        XCTAssertEqual(q.next(canPresent: true)?.item, item(1))
        // SwiftUI dropped it: no markAppeared, no dismissed.
        q.activated()
        XCTAssertNil(q.reviewing)
        XCTAssertEqual(q.next(canPresent: true)?.item, item(1), "the stuck one goes first, not last")
    }

    func testARetriedRecipeIsANewIdentityOfTheSameItem() {
        var q = queue(1)
        let first = q.next(canPresent: true)
        q.activated()
        let retried = q.next(canPresent: true)
        XCTAssertEqual(retried?.item, first?.item)
        XCTAssertNotEqual(retried?.id, first?.id, "a new id, so the sheet sees something new to present")
    }

    func testASheetThatAppearedIsNotRequeuedOnActivation() {
        var q = queue(2)
        let shown = q.next(canPresent: true)
        q.markAppeared()
        q.activated()
        XCTAssertEqual(q.reviewing, shown)
        XCTAssertEqual(q.waiting.count, 1)
        XCTAssertNil(q.next(canPresent: true))
    }

    func testTwoActivationsMidReviewDoNotPresentOverIt() {
        var q = queue(2)
        let shown = q.next(canPresent: true)
        q.markAppeared()
        q.activated()
        XCTAssertNil(q.next(canPresent: true))
        q.activated()
        XCTAssertNil(q.next(canPresent: true))
        XCTAssertEqual(q.reviewing, shown)
    }

    func testAReportArrivingMidReviewIsHeldAndComesOutOnDismissBeforeTheNextRecipe() {
        var q = queue(2)
        _ = q.next(canPresent: true)
        q.markAppeared()
        XCTAssertNil(q.report("Log imported"), "held, not shown over the sheet")
        XCTAssertEqual(q.heldReports, ["Log imported"])
        XCTAssertTrue(q.dismissed())
        XCTAssertEqual(q.takeHeldReport(), "Log imported")
        XCTAssertNil(q.takeHeldReport(), "promoted once")
        // The caller shows the report, so the recipe is told it cannot present
        // until the alert's OK.
        XCTAssertNil(q.next(canPresent: false))
        XCTAssertEqual(q.next(canPresent: true)?.item, item(2))
    }

    func testEveryHeldReportComesOutInOrderBeforeTheNextRecipe() {
        var q = queue(2)
        _ = q.next(canPresent: true)
        q.markAppeared()
        XCTAssertNil(q.report("Couldn't import"))
        XCTAssertNil(q.report("Log imported"))
        q.dismissed()
        XCTAssertEqual(q.takeHeldReport(), "Couldn't import", "the first is never replaced by a later one")
        // A report arriving while the held ones are still being shown waits its turn.
        XCTAssertNil(q.report("Some links didn't import"))
        XCTAssertEqual(q.takeHeldReport(), "Log imported")
        XCTAssertEqual(q.takeHeldReport(), "Some links didn't import")
        XCTAssertNil(q.takeHeldReport())
        XCTAssertEqual(q.next(canPresent: true)?.item, item(2))
    }

    func testAReportWithNoReviewOpenShowsAtOnce() {
        var q = queue(1)
        XCTAssertEqual(q.report("Log imported"), "Log imported")
        XCTAssertTrue(q.heldReports.isEmpty)
    }

    func testDismissAdvancesExactlyOnce() {
        var q = queue(2)
        _ = q.next(canPresent: true)
        q.markAppeared()
        XCTAssertTrue(q.dismissed())
        XCTAssertFalse(q.dismissed(), "a second dismissal is not a second advance")
        XCTAssertEqual(q.next(canPresent: true)?.item, item(2))
        XCTAssertNil(q.next(canPresent: true))
    }

    func testAnUnreadyReviewIsClearedByDismissToo() {
        var q = queue(1)
        _ = q.next(canPresent: true)
        XCTAssertTrue(q.dismissed())
        XCTAssertFalse(q.reviewingAppeared)
    }

    func testRecipesEnqueuedDuringReviewWaitBehindIt() {
        var q = queue(1)
        _ = q.next(canPresent: true)
        q.markAppeared()
        q.enqueue([item(2)])
        q.activated()
        XCTAssertEqual(q.waiting.map(\.item), [item(2)])
        _ = q.dismissed()
        XCTAssertEqual(q.next(canPresent: true)?.item, item(2))
    }

    /// The same page shared twice before LIFT opened, or shared again while
    /// it is open for review, is one review, not two.
    func testTheSameRecipeIsNotQueuedTwice() {
        var q = Queue()
        q.enqueue([item(1), item(2), item(1)])
        XCTAssertEqual(q.waiting.map(\.item), [item(1), item(2)], "a duplicate in one drain")
        q.enqueue([item(2)])
        XCTAssertEqual(q.waiting.map(\.item), [item(1), item(2)], "a duplicate of one still waiting")
        _ = q.next(canPresent: true)
        q.markAppeared()
        q.enqueue([item(1), item(3)])
        XCTAssertEqual(q.waiting.map(\.item), [item(2), item(3)], "a duplicate of the one under review")
    }
}
