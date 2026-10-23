import XCTest
import SwiftData
import LiftCore
@testable import Lift

/// `data.rememberedBarcodes` (BACKUP-FORMAT.md): every remembered food travels
/// in the backup, and a restore merges by code with the newest `updatedAt`
/// winning, so an older file never undoes a correction made since.
@MainActor
final class BackupRememberedFoodTests: XCTestCase {
    private func makeContext() -> ModelContext { ModelContext(LiftStore.makeContainer(inMemory: true)) }
    private func isolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "BackupRememberedFoodTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
    private let flakes = NutritionFacts(calories: 357, proteinG: 7, carbsG: 84, fatG: 0.4, fiberG: 3)

    func testRoundTripKeepsEveryFieldAndBlankStaysBlank() throws {
        let source = makeContext()
        RememberedFoods.remember(code: "36000291452", name: "Corn flakes", per100g: flakes, in: source,
                                 now: Date(timeIntervalSince1970: 1_700_000_000))
        let file = try BackupStore.build(context: source, defaults: isolatedDefaults())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: file) as? [String: Any])
        let section = try XCTUnwrap((json["data"] as? [String: Any])?["rememberedBarcodes"] as? [[String: Any]])
        XCTAssertEqual(section.first?["code"] as? String, "36000291452")
        let per100g = try XCTUnwrap(section.first?["per100g"] as? [String: Any])
        XCTAssertEqual(per100g["fiberG"] as? Double, 3)
        XCTAssertNil(per100g["sodiumMg"], "an unknown nutrient is omitted, not written as 0")
        XCTAssertNil(section.first?["brand"], "a nil brand is omitted")
        XCTAssertEqual(section.first?["updatedAt"] as? Double, 1_700_000_000_000)

        let target = makeContext()
        XCTAssertTrue(BackupStore.restore(context: target, from: file, defaults: isolatedDefaults()).ok)
        let back = try XCTUnwrap(RememberedFoods.find(code: "36000291452", in: target))
        XCTAssertEqual(back.name, "Corn flakes")
        XCTAssertEqual(back.per100g.fiberG, 3)
        XCTAssertNil(back.per100g.sodiumMg)
        XCTAssertNil(back.brand)
        XCTAssertEqual(back.updatedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(BackupStore.storedForeignData()["rememberedBarcodes"],
                     "a section this app stores is not also held as foreign data")
    }

    func testAnOlderBackupNeverOverwritesANewerCorrection() throws {
        let old = makeContext()
        RememberedFoods.remember(code: "36000291452", name: "Corn flakes", per100g: flakes, in: old,
                                 now: Date(timeIntervalSince1970: 1_000))
        let oldFile = try BackupStore.build(context: old, defaults: isolatedDefaults("\(#function).build"))

        let phone = makeContext()
        RememberedFoods.remember(code: "36000291452", name: "Corn flakes (corrected)", per100g: flakes, in: phone,
                                 now: Date(timeIntervalSince1970: 2_000))
        _ = BackupStore.restore(context: phone, from: oldFile, defaults: isolatedDefaults())
        XCTAssertEqual(RememberedFoods.find(code: "36000291452", in: phone)?.name, "Corn flakes (corrected)")
    }

    func testANewerBackupUpdatesAnOlderRememberedFood() throws {
        let newer = makeContext()
        RememberedFoods.remember(code: "36000291452", name: "New name", per100g: flakes, in: newer,
                                 now: Date(timeIntervalSince1970: 3_000))
        let file = try BackupStore.build(context: newer, defaults: isolatedDefaults("\(#function).build"))
        let phone = makeContext()
        RememberedFoods.remember(code: "36000291452", name: "Old name", per100g: flakes, in: phone,
                                 now: Date(timeIntervalSince1970: 1_000))
        _ = BackupStore.restore(context: phone, from: file, defaults: isolatedDefaults())
        XCTAssertEqual(RememberedFoods.find(code: "36000291452", in: phone)?.name, "New name")
        XCTAssertEqual(try phone.fetch(FetchDescriptor<RememberedFood>()).count, 1)
    }

    func testAFileWithoutTheSectionChangesNothing() throws {
        let empty = try BackupStore.build(context: makeContext(), defaults: isolatedDefaults("\(#function).build"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: empty) as? [String: Any])
        XCTAssertNil((json["data"] as? [String: Any])?["rememberedBarcodes"], "no remembered foods, no section")
        let phone = makeContext()
        RememberedFoods.remember(code: "36000291452", name: "Kept", per100g: flakes, in: phone)
        _ = BackupStore.restore(context: phone, from: empty, defaults: isolatedDefaults())
        XCTAssertEqual(RememberedFoods.find(code: "36000291452", in: phone)?.name, "Kept")
    }

    func testAnEntryWithJunkIsSkippedNotFatal() throws {
        let file = try JSONSerialization.data(withJSONObject: [
            "v": 1, "app": "lift", "saved": 0,
            "data": ["rememberedBarcodes": [
                ["code": "36000291452"],
                ["name": "no code"],
                ["code": "36000291453", "name": "bad check digit",
                 "per100g": ["calories": 1, "proteinG": 1, "carbsG": 1, "fatG": 1]],
                "junk"
            ]]
        ] as [String: Any])
        let phone = makeContext()
        XCTAssertTrue(BackupStore.restore(context: phone, from: file, defaults: isolatedDefaults()).ok)
        XCTAssertEqual(try phone.fetch(FetchDescriptor<RememberedFood>()).count, 0,
                       "an entry without a clean code, a name and the four macros is not a food")
    }

    /// A build before this one stored no remembered foods, so it held a file's
    /// `rememberedBarcodes` as foreign data and wrote it back out. That copy
    /// must never stand in for the store's own, and a restore drops it.
    /// The foreign stash lives in `.standard` by `BackupStore`'s design, so
    /// this puts back exactly what was there.
    func testAHeldCopyFromBeforeThisBuildIsNeverWrittenAndIsDropped() throws {
        let key = BackupStore.foreignDataKey
        let previous = UserDefaults.standard.object(forKey: key)
        addTeardownBlock {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let held: [String: Any] = [
            "rememberedBarcodes": [["code": "36000291452", "name": "Held", "updatedAt": 9_000_000_000_000,
                                    "per100g": ["calories": 1, "proteinG": 1, "carbsG": 1, "fatG": 1]]],
            "steps": ["2026-10-01": 9000]
        ]
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: held), forKey: key)

        let file = try BackupStore.build(context: makeContext(), defaults: isolatedDefaults("\(#function).build"))
        let data = try XCTUnwrap((JSONSerialization.jsonObject(with: file) as? [String: Any])?["data"] as? [String: Any])
        XCTAssertNil(data["rememberedBarcodes"], "this phone remembers nothing, so the file says nothing")
        XCTAssertNotNil(data["steps"], "a section this app does not store still goes back out")

        _ = BackupStore.restore(context: makeContext(), from: file, defaults: isolatedDefaults())
        XCTAssertNil(BackupStore.storedForeignData()["rememberedBarcodes"])
        XCTAssertNotNil(BackupStore.storedForeignData()["steps"])
    }

    /// Another build may write a code as scanned rather than normalised. It is
    /// stored under the normalised code and meets the one already remembered,
    /// newest `updatedAt` winning, whether the file wrote epoch ms as an
    /// integer or a double.
    func testACodeWithLeadingZerosMergesWithTheNormalisedOne() throws {
        let phone = makeContext()
        RememberedFoods.remember(code: "36000291452", name: "On the phone", per100g: flakes, in: phone,
                                 now: Date(timeIntervalSince1970: 1_000))

        let per100g: [String: Any] = ["calories": 360, "proteinG": 8, "carbsG": 83, "fatG": 1]
        let file = try JSONSerialization.data(withJSONObject: [
            "v": 1, "app": "lift", "saved": "2026-10-23",
            "data": ["rememberedBarcodes": [
                ["code": "0036000291452", "name": "From Android", "brand": "Kellogg's",
                 "per100g": per100g, "servingGrams": 30,
                 "rememberedAt": 500_000, "updatedAt": 2_000_000],
                // Older than both: never wins, even though it comes last.
                ["code": "036000291452", "name": "Stale", "per100g": per100g,
                 "rememberedAt": 400_000.0, "updatedAt": 1_500_000.0]
            ]]
        ] as [String: Any])

        XCTAssertTrue(BackupStore.restore(context: phone, from: file, defaults: isolatedDefaults()).ok)
        let all = try phone.fetch(FetchDescriptor<RememberedFood>())
        XCTAssertEqual(all.map(\.code), ["36000291452"], "one food, under the normalised code")
        let food = try XCTUnwrap(all.first)
        XCTAssertEqual(food.name, "From Android")
        XCTAssertEqual(food.brand, "Kellogg's")
        XCTAssertEqual(food.servingGrams, 30)
        XCTAssertEqual(food.per100g.calories, 360)
        XCTAssertNil(food.per100g.fiberG, "absent in the file, nil here -- not the phone's old 3")
        XCTAssertEqual(food.updatedAt, Date(timeIntervalSince1970: 2_000))
    }
}
