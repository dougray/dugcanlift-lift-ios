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

    func testTakeAllReturnsOldestFirstAndEmpties() throws {
        let q = try inbox()
        try q.add(item(1)); try q.add(item(2)); try q.add(item(3))
        XCTAssertEqual(q.takeAll(), [item(1), item(2), item(3)])
        XCTAssertEqual(q.takeAll(), [])
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
        XCTAssertEqual(q.takeAll(), [item(1), item(2)])
    }

    func testAnUnreadableFileIsClearedNotLeftToRepeat() throws {
        let q = try inbox()
        try q.add(item(1))
        try Data("not json".utf8).write(to: q.directory.appendingPathComponent("0000000009.json"))
        XCTAssertEqual(q.takeAll(), [item(1)])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: q.directory.path), [])
    }
}
