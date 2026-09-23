import XCTest
@testable import Lift

/// Road Food's file: the spec's "Data format", read leniently, with the
/// development sample kept identical to LIFT web's fixture and the curated
/// file checked the moment it is dropped into `Resources/`.
final class RoadFoodDataTests: XCTestCase {

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "road-food-sample", withExtension: "json"),
                                "Tests/Fixtures/road-food-sample.json is LIFT web's fixture, copied verbatim")
        return try Data(contentsOf: url)
    }

    func testTheSampleFixtureDecodesInTheSpecShapeWithOnlyObviouslyFakeNames() throws {
        let catalog = try RoadFoodCatalog.decode(fixture())
        XCTAssertEqual(catalog.chains.count, 3)
        XCTAssertTrue(catalog.chains.allSatisfy { $0.name.range(of: #"^(Sample|Example|Fictional) "#,
                                                                options: .regularExpression) != nil })
        XCTAssertTrue(catalog.chains.allSatisfy { $0.checkedOn != nil && $0.source != nil && !$0.items.isEmpty })
        XCTAssertEqual(catalog.snacks.count, 3)
        XCTAssertEqual(catalog.chains.first?.kind, "burgers")
        XCTAssertEqual(catalog.rules.last, RoadFoodRule(text: "Ask for a bowl instead of a tortilla", kinds: ["mexican"]))
        XCTAssertEqual(catalog.rules.first, RoadFoodRule(text: "Grilled over fried"))
        // One chain of each kind, so the sample shows all three states: a
        // document dated to the day, one that names only a month, and one that
        // states none.
        let by = { (id: String) in catalog.chains.first { $0.id == id } }
        XCTAssertEqual(by("sample-burger-co")?.publishedOn, "2026-09-02")
        XCTAssertEqual(by("fictional-taco-stand")?.publishedOn, "2024-10")
        XCTAssertNil(by("example-chicken-shack")?.publishedOn)
        // And the month-only one is old on its document date while its checked
        // date is recent, which is the whole point of the field.
        XCTAssertEqual(RoadFoodRanking.isStale(checkedOn: RoadFoodRanking.ageDate(by("fictional-taco-stand")),
                                               today: "2026-09-23"), true)
        XCTAssertEqual(RoadFoodRanking.isStale(checkedOn: by("fictional-taco-stand")?.checkedOn,
                                               today: "2026-09-23"), false)
    }

    func testBlankStaysBlankOnTheWayIn() throws {
        let catalog = try RoadFoodCatalog.decode(fixture())
        let items = catalog.chains[0].items
        let wrap = try XCTUnwrap(items.first { $0.id == "sample-burger-co-mystery-wrap" })
        XCTAssertNil(wrap.proteinG, "protein not listed is nil, never zero")
        XCTAssertNil(wrap.sodiumMg)
        let cola = try XCTUnwrap(items.first { $0.id == "sample-burger-co-diet-test-cola" })
        XCTAssertEqual(cola.kcal, 0, "a listed zero is a zero")
        XCTAssertEqual(cola.sugarG, 0)
        XCTAssertNil(cola.fiberG)
        let salad = try XCTUnwrap(items.first { $0.id == "sample-burger-co-side-salad" })
        XCTAssertNil(salad.saturatedFatG)
        XCTAssertNil(salad.sugarG)
    }

    /// The development sample compiled into DEBUG builds is the same data as
    /// web's fixture, so the simulator shows what the tests test.
    func testTheDebugSampleIsTheWebFixture() throws {
        let fromFile = try JSONSerialization.jsonObject(with: fixture()) as? NSDictionary
        let compiled = try JSONSerialization.jsonObject(with: Data(RoadFoodSample.json.utf8)) as? NSDictionary
        XCTAssertNotNil(fromFile)
        XCTAssertEqual(fromFile, compiled)
    }

    /// The real data's shape (`dugcanlift-kit/data/validate-road-food.mjs`):
    /// snacks carry a brand, an FDC id and slug categories; unknown keys are
    /// ignored; a bad entry is dropped, not fatal; a non-number is not listed.
    func testTheKitShapeAndMalformedEntriesAreReadLeniently() throws {
        let json = #"""
        {
          "version": 1,
          "chains": [
            { "id": "c1", "name": "Chain One", "checkedOn": "2026-09-20", "source": "https://example.com",
              "items": [
                { "id": "c1-a", "name": "A", "serving": "1", "kcal": 300, "proteinG": 30, "fatG": 10,
                  "carbsG": 20, "sodiumMg": "lots", "sugarG": -1, "futureField": true },
                { "id": "c1-b", "kcal": 100 },
                "not an item"
              ] },
            { "name": "No id" },
            { "id": "c2", "name": "Chain Two", "items": [] }
          ],
          "snacks": [
            { "id": "s1", "category": "protein-bar", "brand": "Brandname", "name": "Bar", "serving": "1 bar",
              "barcode": "012345678905", "fdcId": 123, "source": "https://fdc.nal.usda.gov/food-details/123",
              "checkedOn": "2026-09-19", "kcal": 200, "proteinG": 20, "fatG": 7, "carbsG": 22 }
          ],
          "rules": [ "Grilled over fried", { "text": "Bowl", "kinds": ["mexican"] }, 7, { "nope": 1 } ]
        }
        """#
        let catalog = try RoadFoodCatalog.decode(Data(json.utf8))
        XCTAssertEqual(catalog.chains.map(\.id), ["c1", "c2"])
        XCTAssertEqual(catalog.chains[0].items.map(\.id), ["c1-a"], "an item with no name is dropped")
        XCTAssertNil(catalog.chains[0].kind)
        let a = catalog.chains[0].items[0]
        XCTAssertNil(a.sodiumMg, "a string is not a number")
        XCTAssertNil(a.sugarG, "a negative is not a number")
        let bar = try XCTUnwrap(catalog.snacks.first)
        XCTAssertEqual(bar.displayName, "Brandname Bar")
        XCTAssertEqual(bar.checkedOn, "2026-09-19")
        XCTAssertEqual(catalog.snackCategories, ["protein-bar"])
        XCTAssertEqual(catalog.rules, [RoadFoodRule(text: "Grilled over fried"),
                                       RoadFoodRule(text: "Bowl", kinds: ["mexican"])])
    }

    func testAFileWithNoChainsIsNotARoadFoodFile() {
        XCTAssertThrowsError(try RoadFoodCatalog.decode(Data(#"{"version":1}"#.utf8)))
    }

    /// Runs only once `Resources/road-food.json` is in the app (the test
    /// bundle builds `Resources/` too). It is the curated file, so it must
    /// decode, and nothing from the sample may have slipped into it.
    func testTheCuratedFileWhenPresentDecodesAndIsNotTheSample() throws {
        guard let url = Bundle(for: Self.self).url(forResource: "road-food", withExtension: "json") else {
            throw XCTSkip("Resources/road-food.json is not in this build yet")
        }
        let catalog = try RoadFoodCatalog.decode(Data(contentsOf: url))
        XCTAssertFalse(catalog.chains.isEmpty)
        for chain in catalog.chains {
            XCTAssertNil(chain.name.range(of: #"^(Sample|Example|Fictional) "#, options: .regularExpression),
                         "\(chain.name) looks like sample data")
            XCTAssertNotNil(CalendarDay(chain.checkedOn), "\(chain.id) has no usable checkedOn")
            XCTAssertFalse(chain.items.isEmpty, "\(chain.id) has no items")
            // A document cannot have been published after the day someone read it.
            if let published = chain.publishedOn {
                guard let day = RoadFoodRanking.docDay(published) else {
                    return XCTFail("\(chain.id) has an unusable publishedOn")
                }
                XCTAssertLessThanOrEqual(day, CalendarDay(chain.checkedOn)!,
                                         "\(chain.id) claims a document published after it was read")
            }
        }
        XCTAssertFalse(catalog.rules.isEmpty)
        // The three charts this field exists for: each looks fresh by the day
        // it was read and is old by its own date.
        for id in ["burgerking", "whataburger", "chipotle"] {
            guard let chain = catalog.chains.first(where: { $0.id == id }) else {
                return XCTFail("the curated file has no \(id)")
            }
            XCTAssertEqual(RoadFoodRanking.isStale(checkedOn: chain.checkedOn, today: "2026-09-23"), false,
                           "\(id) looks fresh by checkedOn alone")
            XCTAssertEqual(RoadFoodRanking.isStale(checkedOn: RoadFoodRanking.ageDate(chain), today: "2026-09-23"), true,
                           "\(id) should be old by its own chart")
        }
        XCTAssertEqual(catalog.chains.first(where: { $0.id == "burgerking" })?.publishedOn, "2022-11")
        XCTAssertEqual(catalog.chains.first(where: { $0.id == "whataburger" })?.publishedOn, "2021-03-29")
        XCTAssertEqual(catalog.chains.first(where: { $0.id == "chipotle" })?.publishedOn, "2024-10")
        // Blank stays blank: a chain whose document states no date has no key.
        XCTAssertNil(catalog.chains.first(where: { $0.id == "sonic" })?.publishedOn)
        XCTAssertNil(catalog.chains.first(where: { $0.id == "quiktrip" })?.publishedOn)
    }

    /// Seen on a gas-station row before it was fixed: the curated names lead
    /// with the brand, so prefixing it again said it twice.
    func testABrandTheNameAlreadySaysIsNotSaidTwice() throws {
        let catalog = try XCTUnwrap(RoadFoodCatalog.bundled(in: Bundle(for: RoadFoodDataTests.self))?.catalog)
        let jerky = try XCTUnwrap(catalog.snacks.first { $0.id == "snack-jack-links-original-beef-jerky" })
        XCTAssertEqual(jerky.brand, "Jack Link's")
        XCTAssertEqual(jerky.displayName, "Jack Link's Original Beef Jerky")
        for snack in catalog.snacks {
            guard let brand = snack.brand, !brand.isEmpty else { continue }
            XCTAssertFalse(snack.displayName.localizedCaseInsensitiveContains("\(brand) \(brand)"),
                           snack.displayName)
        }
        // A brand the name does not say is still carried.
        XCTAssertEqual(RoadFoodItem(id: "x", name: "Bar", brand: "Brandname").displayName,
                       "Brandname Bar")
    }
}
