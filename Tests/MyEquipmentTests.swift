import XCTest
import LiftReference
@testable import Lift

final class MyEquipmentTests: XCTestCase {

    func testOwningEverythingHidesNothing() {
        XCTAssertTrue(MyEquipment.allows("barbell", notOwned: []))
        let records = ["barbell", "cable", nil]
        let result = MyEquipment.filter(records, notOwned: [], equipment: { $0 })
        XCTAssertEqual(result.shown, records)
        XCTAssertEqual(result.leftOut, 0)
    }

    func testWhatYouDoNotHaveIsLeftOutAndCounted() {
        let records = ["barbell", "cable", "dumbbell", "Cable "]
        let result = MyEquipment.filter(records, notOwned: ["cable"], equipment: { $0 })
        XCTAssertEqual(result.shown, ["barbell", "dumbbell"])
        XCTAssertEqual(result.leftOut, 2)
    }

    /// Unknown is not "needs something you lack".
    func testAnExerciseWithNoEquipmentListedAlwaysShows() {
        let everything = Set(MyEquipment.kinds.map(\.id))
        XCTAssertTrue(MyEquipment.allows(nil, notOwned: everything))
        XCTAssertTrue(MyEquipment.allows("  ", notOwned: everything))
    }

    func testOwningEverythingStoresNoKey() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        addTeardownBlock { defaults.removePersistentDomain(forName: #function) }

        XCTAssertEqual(MyEquipment.load(from: defaults), [])
        MyEquipment.save(["cable", "machine"], to: defaults)
        XCTAssertEqual(MyEquipment.load(from: defaults), ["cable", "machine"])
        MyEquipment.save([], to: defaults)
        XCTAssertNil(defaults.object(forKey: MyEquipment.storageKey))
    }

    /// A value in the data with no switch could never be turned off, and
    /// that exercise would show for someone who has none of it.
    func testEveryEquipmentValueInTheDataHasASwitch() async throws {
        let all = try await ReferenceDatabase.shared.allExercises(limit: 5000)
        XCTAssertGreaterThan(all.count, 800)
        let known = Set(MyEquipment.kinds.map(\.id))
        let values = Set(all.map { MyEquipment.normalised($0.equipment) }).subtracting([""])
        XCTAssertEqual(values.subtracting(known), [])
    }
}
