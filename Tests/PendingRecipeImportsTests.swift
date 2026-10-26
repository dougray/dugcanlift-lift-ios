import XCTest
@testable import Lift

final class PendingRecipeImportsTests: XCTestCase {

    private func inbox() throws -> PendingRecipeImports {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingRecipeImportsTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return PendingRecipeImports(directory: dir)
    }

    private func item(_ n: Int) -> PendingRecipeImports.Item {
        .init(block: #"{"@type":"Recipe","name":"Dish \#(n)"}"#, pageURL: "https://example.org/\(n)")
    }

    /// Reading for review leaves every recipe in place: one is deleted only
    /// when its review ends in Save or Cancel. Emptying the queue on reading
    /// lost a recipe whenever iOS ended LIFT with its review open.
    func testReadingForReviewLeavesTheQueueAsItWas() throws {
        let q = try inbox()
        try q.add(item(1)); try q.add(item(2)); try q.add(item(3))
        XCTAssertEqual(q.forReview(), [item(1), item(2), item(3)])
        XCTAssertEqual(q.forReview(), [item(1), item(2), item(3)])
    }

    func testAFinishedReviewRemovesThatRecipeOnly() throws {
        let q = try inbox()
        try q.add(item(1)); try q.add(item(2))
        q.remove(item(1))
        XCTAssertEqual(q.forReview(), [item(2)])
    }

    /// A page whose review never ends -- it crashes LIFT, say -- must not
    /// open on every launch for ever. Two unfinished opens keep it.
    func testARecipeOpenedThreeTimesWithoutFinishingIsGivenUp() throws {
        let q = try inbox()
        try q.add(item(1)); try q.add(item(2))
        q.markOpened(item(1)); q.markOpened(item(1))
        XCTAssertEqual(q.forReview(), [item(1), item(2)])
        q.markOpened(item(1))
        XCTAssertEqual(q.forReview(), [item(2)])
        XCTAssertEqual(q.pending, [item(2)], "its file is gone, not just skipped")
    }

    /// Mid-process reads keep a recipe at the limit: the give-up is a launch's.
    func testTheGiveUpCanBeHeldOff() throws {
        let q = try inbox()
        try q.add(item(1))
        for _ in 0..<PendingRecipeImports.mostOpens { q.markOpened(item(1)) }
        XCTAssertEqual(q.forReview(givingUp: false), [item(1)])
        XCTAssertEqual(q.forReview(), [])
    }

    /// An open that never came on screen is given back, and never below none.
    func testAnOpenCanBeGivenBack() throws {
        let q = try inbox()
        try q.add(item(1))
        q.unmarkOpened(item(1))
        for _ in 0..<PendingRecipeImports.mostOpens { q.markOpened(item(1)) }
        q.unmarkOpened(item(1))
        XCTAssertEqual(q.forReview(), [item(1)])
        q.markOpened(item(1))
        XCTAssertEqual(q.forReview(), [])
    }

    func testOpeningIsCountedPerRecipe() throws {
        let q = try inbox()
        try q.add(item(1)); try q.add(item(2))
        for _ in 0..<PendingRecipeImports.mostOpens { q.markOpened(item(2)) }
        XCTAssertEqual(q.forReview(), [item(1)])
    }

    /// Sharing the page again is the lifter asking for it again.
    func testSharingAgainStartsTheCountAfresh() throws {
        let q = try inbox()
        try q.add(item(1))
        q.markOpened(item(1)); q.markOpened(item(1))
        try q.add(item(1))
        q.markOpened(item(1))
        XCTAssertEqual(q.forReview(), [item(1)])
    }

    /// The count is the queue's business, not the recipe's: an opened recipe
    /// is still the same recipe, block and address unchanged.
    func testOpeningDoesNotChangeTheRecipe() throws {
        let q = try inbox()
        try q.add(item(1))
        q.markOpened(item(1))
        let read = try XCTUnwrap(q.forReview().first)
        XCTAssertEqual(read, item(1))
        XCTAssertEqual(read.block, item(1).block)
        XCTAssertEqual(read.pageURL, item(1).pageURL)
    }

    /// A file the share extension wrote before the count existed still reads.
    func testAFileWithNoCountReads() throws {
        let q = try inbox()
        try FileManager.default.createDirectory(at: q.directory, withIntermediateDirectories: true)
        try Data(#"{"block":"{}","pageURL":"https://example.org/old"}"#.utf8)
            .write(to: q.directory.appendingPathComponent("0000000001.json"))
        XCTAssertEqual(q.forReview().map(\.pageURL), ["https://example.org/old"])
    }

    func testTheSamePageSharedTwiceIsQueuedOnce() throws {
        let q = try inbox()
        try q.add(item(1)); try q.add(item(2)); try q.add(item(1))
        XCTAssertEqual(q.pending, [item(2), item(1)])
    }

    func testBeyondTheLimitTheOldestIsDropped() throws {
        let q = try inbox()
        for n in 1...(PendingRecipeImports.limit + 1) { try q.add(item(n)) }
        let kept = q.pending
        XCTAssertEqual(kept.count, PendingRecipeImports.limit)
        XCTAssertEqual(kept.first, item(2))
        XCTAssertEqual(kept.last, item(PendingRecipeImports.limit + 1))
    }

    /// Order comes from the sequence number in the file name, never from a
    /// file timestamp -- reading those is a required-reason API.
    func testOrderComesFromTheFileNameNotTheClock() throws {
        let q = try inbox()
        try FileManager.default.createDirectory(at: q.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(item(2)).write(to: q.directory.appendingPathComponent("0000000002.json"))
        try JSONEncoder().encode(item(1)).write(to: q.directory.appendingPathComponent("0000000001.json"))
        XCTAssertEqual(q.forReview(), [item(1), item(2)])
    }

    func testAnUnreadableFileIsClearedNotLeftToRepeat() throws {
        let q = try inbox()
        try q.add(item(1))
        try Data("not json".utf8).write(to: q.directory.appendingPathComponent("0000000009.json"))
        XCTAssertEqual(q.forReview(), [item(1)])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: q.directory.path).count, 1)
    }
}
