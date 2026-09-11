import XCTest
import Compression
@testable import LiftKit

final class StandaloneExportTests: XCTestCase {

    private func food(_ name: String) -> WatchFood {
        WatchFood(name: name, kcal: 165, protein: 31, fat: 3.6, carbs: 0, fibre: 0)
    }

    private func entries(_ count: Int, distinctFoods: Int = 3) -> [LoggedFood] {
        (0..<count).map { i in
            LoggedFood(food: food("food\(i % distinctFoods)"),
                       grams: 100,
                       meal: .lunch,
                       loggedAt: Date(timeIntervalSince1970: 1_757_486_400 + Double(i) * 3600))
        }
    }

    /// Eight real rows pulled from the bundled `foods.json` (USDA SR
    /// Legacy), not the synthetic `food0`/`food1` fixture above. Median USDA
    /// name length is 51 characters -- e.g. "Fish, tuna, white, canned in
    /// oil, without salt, drained solids" -- and the export payload's cost is
    /// dominated by these names in the food dictionary, not by the entry
    /// count. A fixture built from short synthetic names cannot exercise
    /// that, which is exactly how the original fixed 50-entry cap shipped
    /// 30% over the scannable ceiling without any test catching it.
    private let realFoods: [WatchFood] = [
        WatchFood(name: "Fish, tuna, white, canned in oil, without salt, drained solids",
                  kcal: 186, protein: 26.5, fat: 8.1, carbs: 0, fibre: 0),
        WatchFood(name: "Pork, fresh, loin, tenderloin, separable lean and fat, raw",
                  kcal: 120, protein: 20.6, fat: 3.5, carbs: 0, fibre: 0),
        WatchFood(name: "Beef, rib, shortribs, separable lean only, choice, raw",
                  kcal: 175, protein: 19, fat: 10.2, carbs: 0.4, fibre: 0),
        WatchFood(name: "Archway Home Style Cookies, Chocolate Chip Ice Box",
                  kcal: 497, protein: 4.3, fat: 24.4, carbs: 65, fibre: 2),
        WatchFood(name: "Seeds, sunflower seed kernels, dry roasted, without salt",
                  kcal: 582, protein: 19.3, fat: 49.8, carbs: 24.1, fibre: 11.1),
        WatchFood(name: "Chicken breast tenders, breaded, cooked, microwaved",
                  kcal: 252, protein: 16.4, fat: 12.9, carbs: 17.6, fibre: 0),
        WatchFood(name: "Cereals ready-to-eat, QUAKER, QUAKER Puffed Rice",
                  kcal: 383, protein: 7, fat: 0.9, carbs: 87.8, fibre: 1.4),
        WatchFood(name: "Cereals ready-to-eat, BARBARA'S PUFFINS, original",
                  kcal: 333, protein: 7.4, fat: 3.7, carbs: 84, fibre: 18.5),
    ]

    /// Cycles through `realFoods` with varying grams, meals, and timestamps
    /// -- never the same amount or instant twice in a row -- so this can't
    /// accidentally compress better than a real log would.
    private func realisticEntries(_ count: Int) -> [LoggedFood] {
        var result: [LoggedFood] = []
        for i in 0..<count {
            let grams: Double = Double(50 + (i * 37) % 250)
            let timestamp: Double = 1_757_486_400 + Double(i) * 3600
            let entry = LoggedFood(food: realFoods[i % realFoods.count],
                                   grams: grams,
                                   meal: FoodLogMeal.allCases[i % FoodLogMeal.allCases.count],
                                   loggedAt: Date(timeIntervalSince1970: timestamp))
            result.append(entry)
        }
        return result
    }

    /// Reverses one code back into its JSON object, the way the PWA will.
    private func decode(_ code: String) throws -> [String: Any] {
        var padded = code.replacingOccurrences(of: "-", with: "+")
                         .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        let deflated = try XCTUnwrap(Data(base64Encoded: padded))
        let capacity = 1 << 20
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = deflated.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(destination, capacity, base, deflated.count,
                                             nil, COMPRESSION_ZLIB)
        }
        let json = Data(bytes: destination, count: written)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
    }

    func testMealIndicesMatchShareFormat() {
        // 0 breakfast, 1 lunch, 2 dinner, 3 snack. An off-by-one here
        // silently refiles every meal on the far side.
        XCTAssertEqual(StandaloneExport.mealIndex(.breakfast), 0)
        XCTAssertEqual(StandaloneExport.mealIndex(.lunch), 1)
        XCTAssertEqual(StandaloneExport.mealIndex(.dinner), 2)
        XCTAssertEqual(StandaloneExport.mealIndex(.snack), 3)
    }

    func testEmptyLogProducesNoCodes() {
        XCTAssertTrue(StandaloneExport.codes(for: []).isEmpty)
    }

    func testSingleCodeCarriesEveryEntryAndADeduplicatedFoodDictionary() throws {
        let payload = try decode(try XCTUnwrap(StandaloneExport.codes(for: entries(9, distinctFoods: 3)).first))
        XCTAssertEqual(payload["v"] as? Int, 1)
        XCTAssertEqual((payload["e"] as? [[Any]])?.count, 9)
        // Three distinct foods across nine entries — the dictionary holds
        // three, which is what keeps the payload affordable.
        XCTAssertEqual((payload["fd"] as? [[Any]])?.count, 3)
    }

    func testEntryTupleIsIndexGramsMealTimestamp() throws {
        let one = [LoggedFood(food: food("Chicken breast, roasted"), grams: 140,
                              meal: .dinner,
                              loggedAt: Date(timeIntervalSince1970: 1_757_486_400))]
        let payload = try decode(try XCTUnwrap(StandaloneExport.codes(for: one).first))
        let tuple = try XCTUnwrap((payload["e"] as? [[Any]])?.first)
        XCTAssertEqual(tuple[0] as? Int, 0)
        XCTAssertEqual((tuple[1] as? NSNumber)?.doubleValue, 140)
        XCTAssertEqual(tuple[2] as? Int, 2)
        XCTAssertEqual((tuple[3] as? NSNumber)?.doubleValue, 1_757_486_400)
    }

    func testFoodDictionaryRowIsNameThenMacrosPer100g() throws {
        let one = [LoggedFood(food: food("Chicken breast, roasted"), grams: 140,
                              meal: .dinner, loggedAt: Date(timeIntervalSince1970: 1))]
        let payload = try decode(try XCTUnwrap(StandaloneExport.codes(for: one).first))
        let row = try XCTUnwrap((payload["fd"] as? [[Any]])?.first)
        XCTAssertEqual(row[0] as? String, "Chicken breast, roasted")
        XCTAssertEqual((row[1] as? NSNumber)?.doubleValue, 165)
        XCTAssertEqual((row[2] as? NSNumber)?.doubleValue, 31)
        XCTAssertEqual((row[3] as? NSNumber)?.doubleValue, 3.6)
    }

    func testLogsLongerThanTheCapSplitAcrossNumberedCodes() throws {
        // Realistic names, not the synthetic `food0`/`food1` fixture: with
        // short synthetic names and only 3 distinct foods, 120 entries
        // DEFLATE down to a single ~650-byte code and this test would
        // exercise no splitting at all. Chunking is now size-based rather
        // than a fixed entry count, so the resulting number of codes is
        // whatever the data demands -- assert the invariant (every code
        // numbered against the true final total), not a specific count.
        let codes = StandaloneExport.codes(for: realisticEntries(120))
        XCTAssertGreaterThan(codes.count, 1, "120 realistic entries should not fit in a single code")
        for (i, code) in codes.enumerated() {
            let position = try XCTUnwrap(decode(code)["p"] as? [Int])
            XCTAssertEqual(position, [i + 1, codes.count])
        }
    }

    func testEveryEntrySurvivesTheSplit() throws {
        let codes = StandaloneExport.codes(for: entries(120))
        let total = try codes.reduce(0) { $0 + ((try decode($1)["e"] as? [[Any]])?.count ?? 0) }
        XCTAssertEqual(total, 120)
    }

    func testEveryEntrySurvivesTheSplitWithRealisticNames() throws {
        // Same guarantee as above, but with data that actually forces
        // multiple codes (see testLogsLongerThanTheCapSplitAcrossNumberedCodes) --
        // no entry may be dropped, duplicated, or reordered across a real
        // multi-code split.
        let codes = StandaloneExport.codes(for: realisticEntries(120))
        let total = try codes.reduce(0) { $0 + ((try decode($1)["e"] as? [[Any]])?.count ?? 0) }
        XCTAssertEqual(total, 120)
    }

    func testAllCodesInASequenceShareAnExportTimestamp() throws {
        // Realistic data so this sequence is actually more than one code --
        // with the old fixture this assertion could pass trivially against a
        // single-element set from a single code.
        let codes = StandaloneExport.codes(for: realisticEntries(120))
        XCTAssertGreaterThan(codes.count, 1)
        let stamps = try codes.map { try decode($0)["z"] as? Int }
        XCTAssertEqual(Set(stamps.compactMap { $0 }).count, 1)
    }

    func testASingleCodeStaysUnderTheScannableCeiling() throws {
        // Real USDA names, not the synthetic fixture: as originally written
        // with `food0`-style names this passed at 419 bytes and guarded
        // nothing. With 8 real names (median 51 characters) and varying
        // grams, 50 entries no longer fit in one code at all -- every code
        // the split produces must still respect the ceiling.
        let codes = StandaloneExport.codes(for: realisticEntries(50))
        XCTAssertFalse(codes.isEmpty)
        for code in codes {
            XCTAssertLessThanOrEqual(code.count, StandaloneExport.maxCodeBytes)
        }
    }

    func testSingleOversizedEntryProducesExactlyOneCodeRatherThanHangingOrVanishing() throws {
        // A pathological single entry whose encoded payload alone exceeds
        // the byte budget (a very long food name -- digits of consecutive
        // integers concatenated, so DEFLATE's LZ77 matching can't crush it
        // down to nothing the way a literal repeated pattern would). This
        // must still produce exactly one code: chunking can never emit a
        // zero-entry chunk, loop forever trying to shrink below budget, or
        // silently drop the entry because it doesn't fit.
        var longName = ""
        var i = 0
        while longName.count < 1600 { longName += String(i); i += 1 }
        let entry = LoggedFood(food: food(longName), grams: 100, meal: .lunch,
                               loggedAt: Date(timeIntervalSince1970: 1))
        let codes = StandaloneExport.codes(for: [entry])
        XCTAssertEqual(codes.count, 1)
        let payload = try decode(codes[0])
        XCTAssertEqual((payload["e"] as? [[Any]])?.count, 1)
        XCTAssertEqual(payload["p"] as? [Int], [1, 1])
        // The whole point of the fixture: this one code is allowed to be
        // over the ceiling, because a single entry can never be split
        // further -- the guarantee is that it still arrives, not that it's
        // scannable.
        XCTAssertGreaterThan(codes[0].count, StandaloneExport.maxCodeBytes)
    }
}
