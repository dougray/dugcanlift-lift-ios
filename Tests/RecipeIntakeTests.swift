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
        intake.appeared()
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
        intake.appeared()
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
        intake.appeared()
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
        intake.appeared()
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
        intake.appeared()
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
}
