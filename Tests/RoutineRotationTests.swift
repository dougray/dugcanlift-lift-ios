import XCTest
@testable import Lift

final class RoutineRotationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func day(_ n: Int) -> Date { start.addingTimeInterval(Double(n) * 86_400) }

    private func member(_ name: String, made n: Int) -> RoutineRotation.Member {
        RoutineRotation.Member(id: UUID(), createdAt: day(n), name: name, exerciseIDs: [UUID(), UUID()])
    }

    private func trained(_ member: RoutineRotation.Member, on n: Int) -> RoutineRotation.Day {
        RoutineRotation.Day(date: day(n),
                            exerciseRefIDs: Set(member.exerciseIDs.prefix(1).map(RoutineRotation.refID)))
    }

    private lazy var push = member("Push", made: 0)
    private lazy var pull = member("Pull", made: 1)
    private lazy var legs = member("Legs", made: 2)
    private var ppl: [RoutineRotation.Member] { [legs, push, pull] }

    func testBeforeAnyIsStartedTheFirstMadeIsUpNext() {
        let next = RoutineRotation.upNext(folder: "PPL", members: ppl, days: [])
        XCTAssertEqual(next, .init(routineID: push.id, after: nil, lastDate: nil))
    }

    func testTheOneAfterTheLastStartedIsUpNextAndItWrapsRound() {
        XCTAssertEqual(RoutineRotation.upNext(folder: "PPL", members: ppl,
                                              days: [trained(push, on: 10)])?.routineID, pull.id)
        XCTAssertEqual(RoutineRotation.upNext(folder: "PPL", members: ppl,
                                              days: [trained(push, on: 10), trained(legs, on: 12)])?.routineID,
                       push.id)
    }

    /// Order is the order of the days, not of the list it was handed in.
    func testTheNewestDayDecides() {
        let days = [trained(legs, on: 12), trained(pull, on: 14), trained(push, on: 10)]
        XCTAssertEqual(RoutineRotation.upNext(folder: "PPL", members: ppl, days: days)?.routineID, legs.id)
    }

    /// A day logged by hand, or from another folder, moves nothing on.
    func testADayFromNoRoutineOfTheFolderIsIgnored() {
        let other = RoutineRotation.Day(date: day(20), exerciseRefIDs: ["exercise-db-id", "routine:\(UUID())"])
        let days = [trained(push, on: 10), other]
        XCTAssertEqual(RoutineRotation.upNext(folder: "PPL", members: ppl, days: days)?.routineID, pull.id)
    }

    func testOneRoutineOrTheDefaultFolderIsNoRotation() {
        XCTAssertNil(RoutineRotation.upNext(folder: "PPL", members: [push], days: []))
        XCTAssertNil(RoutineRotation.upNext(folder: "", members: ppl, days: []))
        XCTAssertNil(RoutineRotation.upNext(folder: "  ", members: ppl, days: []))
    }

    /// Two made at once (the same instant) go by name, so the order is stable.
    func testATieInWhenTheyWereMadeGoesByName() {
        let b = RoutineRotation.Member(id: UUID(), createdAt: start, name: "Day B", exerciseIDs: [UUID()])
        let a = RoutineRotation.Member(id: UUID(), createdAt: start, name: "Day A", exerciseIDs: [UUID()])
        XCTAssertEqual(RoutineRotation.ordered([b, a]).map(\.name), ["Day A", "Day B"])
    }

    func testTheCurrentRotationIsTheOneTrainedMostRecently() {
        let upper = member("Upper", made: 3)
        let lower = member("Lower", made: 4)
        let folders = [(folder: "PPL", members: ppl), (folder: "Upper/Lower", members: [upper, lower])]
        let days = [trained(push, on: 10), trained(upper, on: 15)]
        let current = RoutineRotation.current(folders, days: days)
        XCTAssertEqual(current?.folder, "Upper/Lower")
        XCTAssertEqual(current?.upNext.routineID, lower.id)
    }

    /// Nobody asked for the first routine of every folder.
    func testNoRotationStartedSuggestsNothing() {
        XCTAssertNil(RoutineRotation.current([(folder: "PPL", members: ppl)], days: []))
    }
}
