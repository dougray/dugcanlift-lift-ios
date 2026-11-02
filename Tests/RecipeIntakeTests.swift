import XCTest
@testable import Lift

/// What the app root does with a recipe Safari handed over, against a real
/// file queue. iOS ending LIFT is a new `RecipeIntake` on the same folder:
/// everything in memory is gone and only the files remain.
final class RecipeIntakeTests: XCTestCase {

    private typealias Intake = RecipeIntake<String>

    private func folder() throws -> PendingRecipeImports {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecipeIntakeTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return PendingRecipeImports(directory: dir)
    }

    private func item(_ n: Int) -> PendingRecipeImports.Item {
        .init(block: #"{"@type":"Recipe","name":"Dish \#(n)"}"#, pageURL: "https://example.org/\(n)")
    }

    /// A review that came on screen and was not finished, then iOS ended LIFT.
    private func reviewThenTerminate(_ files: PendingRecipeImports) {
        var intake = Intake(inbox: files)
        intake.activated()
        _ = intake.next(canPresent: true)
        intake.appeared(intake.reviewing!.id)
    }

    func testARecipeEndedMidReviewComesBack() throws {
        let files = try folder()
        try files.add(item(1))
        reviewThenTerminate(files)
        var relaunched = Intake(inbox: files)
        relaunched.activated()
        XCTAssertEqual(relaunched.next(canPresent: true)?.item, item(1))
    }

    /// Save or Cancel deletes the file as the sheet starts to close, not after
    /// its animation: being ended in between must not reopen a saved recipe.
    func testClosingAReviewDeletesItsFileAtOnce() throws {
        let files = try folder()
        try files.add(item(1)); try files.add(item(2))
        var intake = Intake(inbox: files)
        intake.activated()
        _ = intake.next(canPresent: true)
        intake.appeared(intake.reviewing!.id)
        intake.closing()
        XCTAssertEqual(files.pending, [item(2)])
        intake.closed()
        XCTAssertEqual(files.pending, [item(2)])
    }

    /// Nothing opens until the closing sheet has gone: opening during the
    /// animation let the old sheet's `onDismiss` end the new review and delete
    /// a recipe nobody had seen.
    func testNothingOpensWhileAReviewIsClosing() throws {
        let files = try folder()
        try files.add(item(1)); try files.add(item(2))
        var intake = Intake(inbox: files)
        intake.activated()
        _ = intake.next(canPresent: true)
        intake.appeared(intake.reviewing!.id)
        intake.closing()
        intake.activated()
        XCTAssertNil(intake.next(canPresent: true))
        intake.closed()
        XCTAssertEqual(intake.next(canPresent: true)?.item, item(2))
        XCTAssertEqual(files.pending, [item(2)], "the second recipe's file is untouched")
    }

    /// A sheet SwiftUI dropped never ran, so it did not crash LIFT: its try
    /// is given back. Without that, coming back to LIFT three times with
    /// another sheet up gave up a recipe the lifter never saw.
    func testASheetThatNeverAppearedIsNotATry() throws {
        let files = try folder()
        try files.add(item(1))
        var intake = Intake(inbox: files)
        intake.activated()
        for _ in 0..<(PendingRecipeImports.mostOpens + 2) {
            _ = intake.next(canPresent: true)
            intake.activated()
        }
        var relaunched = Intake(inbox: files)
        relaunched.activated()
        XCTAssertEqual(relaunched.next(canPresent: true)?.item, item(1))
    }

    /// A review that ends LIFT every time is given up, at a launch.
    func testARecipeThatEndsLIFTEveryTimeIsGivenUp() throws {
        let files = try folder()
        try files.add(item(1)); try files.add(item(2))
        for _ in 0..<PendingRecipeImports.mostOpens { reviewThenTerminate(files) }
        var relaunched = Intake(inbox: files)
        relaunched.activated()
        XCTAssertEqual(relaunched.next(canPresent: true)?.item, item(2))
        XCTAssertEqual(files.pending, [item(2)], "its file is gone")
    }

    /// The give-up is for launches only. The third review on screen is not a
    /// third crash; coming back from Safari to compare must not delete it.
    func testTheLastTryIsNotGivenUpWhileItIsOnScreen() throws {
        let files = try folder()
        try files.add(item(1))
        for _ in 0..<(PendingRecipeImports.mostOpens - 1) { reviewThenTerminate(files) }
        var intake = Intake(inbox: files)
        intake.activated()
        XCTAssertEqual(intake.next(canPresent: true)?.item, item(1))
        intake.appeared(intake.reviewing!.id)
        intake.activated()
        XCTAssertEqual(files.pending, [item(1)])
        XCTAssertEqual(intake.reviewing?.item, item(1))
    }

    /// Reading the files on every activation must not queue what is already
    /// waiting or under review.
    func testActivatingAgainQueuesNothingTwice() throws {
        let files = try folder()
        try files.add(item(1)); try files.add(item(2))
        var intake = Intake(inbox: files)
        intake.activated()
        _ = intake.next(canPresent: true)
        intake.appeared(intake.reviewing!.id)
        intake.activated()
        intake.activated()
        XCTAssertEqual(intake.waiting.map(\.item), [item(2)])
    }

    /// Without the App Group (a build missing its entitlement) there is
    /// nothing to read and nothing breaks.
    func testWithNoInboxNothingIsQueued() {
        var intake = Intake(inbox: nil)
        intake.activated()
        XCTAssertNil(intake.next(canPresent: true))
    }

    // MARK: Only what came on screen can finish

    /// A sheet's `onDismiss` can arrive for a sheet that never showed -- one
    /// SwiftUI replaced when the review was retried. It must not end the
    /// retry or delete a recipe nobody saw.
    func testADismissForASheetThatNeverShowedDeletesNothing() throws {
        let files = try folder()
        try files.add(item(1))
        var intake = Intake(inbox: files)
        intake.activated()
        _ = intake.next(canPresent: true)
        intake.activated()
        let retry = try XCTUnwrap(intake.next(canPresent: true))
        intake.closed()
        XCTAssertEqual(files.pending, [item(1)])
        XCTAssertEqual(intake.reviewing?.id, retry.id)
    }

    /// The binding cleared for a review that never came on screen is a
    /// dropped sheet, not a Save: retried, its try given back, and nothing
    /// left waiting on a close that will never come.
    func testClearingAReviewThatNeverShowedIsADrop() throws {
        let files = try folder()
        try files.add(item(1))
        var intake = Intake(inbox: files)
        intake.activated()
        _ = intake.next(canPresent: true)
        intake.closing()
        XCTAssertEqual(files.pending, [item(1)])
        XCTAssertEqual(intake.next(canPresent: true)?.item, item(1), "not stuck closing")
        for _ in 0..<(PendingRecipeImports.mostOpens + 1) {
            intake.closing()
            _ = intake.next(canPresent: true)
        }
        var relaunched = Intake(inbox: files)
        relaunched.activated()
        XCTAssertEqual(relaunched.next(canPresent: true)?.item, item(1), "drops are not tries")
    }

    /// An old sheet's late `onAppear` does not count as the retry appearing.
    func testAppearingCountsOnlyForTheSheetOnScreen() throws {
        let files = try folder()
        try files.add(item(1))
        var intake = Intake(inbox: files)
        intake.activated()
        let first = try XCTUnwrap(intake.next(canPresent: true))
        intake.activated()
        _ = intake.next(canPresent: true)
        intake.appeared(first.id)
        intake.closing()
        XCTAssertEqual(files.pending, [item(1)], "the retry had not appeared, so nothing finished")
    }

    // MARK: A recipe from the bookmarklet

    /// A bookmarklet recipe is a Safari share from here on: it is on disk
    /// before its review opens, so iOS ending LIFT mid-review loses nothing.
    func testABookmarkletRecipeIsQueuedLikeASafariShare() throws {
        let files = try folder()
        var intake = Intake(inbox: files)
        intake.activated()
        intake.received(item(1))
        XCTAssertEqual(files.pending, [item(1)])
        XCTAssertEqual(intake.next(canPresent: true)?.item, item(1))
        intake.appeared(intake.reviewing!.id)
        var relaunched = Intake(inbox: files)
        relaunched.activated()
        XCTAssertEqual(relaunched.next(canPresent: true)?.item, item(1), "ended mid-review, it comes back")
    }

    /// The link can land before the activation that reads the files, or after
    /// it: either way the recipe is one review, not two.
    func testTheSameRecipeArrivingTwoWaysIsOneReview() throws {
        let files = try folder()
        var intake = Intake(inbox: files)
        intake.received(item(1))
        intake.activated()
        intake.received(item(1))
        XCTAssertEqual(intake.waiting.map(\.item), [item(1)])
        XCTAssertEqual(files.pending, [item(1)])
    }

    /// One at a time: a recipe sent while another is under review waits, and
    /// Save or Cancel on the first deletes only the first.
    func testABookmarkletRecipeWaitsForTheReviewOnScreen() throws {
        let files = try folder()
        try files.add(item(1))
        var intake = Intake(inbox: files)
        intake.activated()
        _ = intake.next(canPresent: true)
        intake.appeared(intake.reviewing!.id)
        intake.received(item(2))
        XCTAssertNil(intake.next(canPresent: true), "nothing opens over a review")
        intake.closing()
        intake.closed()
        XCTAssertEqual(files.pending, [item(2)])
        XCTAssertEqual(intake.next(canPresent: true)?.item, item(2))
    }

    /// No App Group in the running build: the recipe still opens, held in memory.
    func testABookmarkletRecipeOpensWithoutTheAppGroup() {
        var intake = Intake(inbox: nil)
        intake.activated()
        intake.received(item(1))
        XCTAssertEqual(intake.next(canPresent: true)?.item, item(1))
    }
}
