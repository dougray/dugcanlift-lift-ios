import Foundation

/// Road Food's bundled file: fast-food chains and gas-station snacks, curated
/// by hand from each chain's own published nutrition. The format is the spec's
/// "Data format" (`dugcanlift-wip-backups/lift-road-food-spec.md`), the same
/// file on every platform; the source of record is
/// `dugcanlift-kit/data/road-food.json`.
///
/// **Where it lives.** `Resources/road-food.json` in the LIFT app target. Not
/// `LiftReference`, where the spec suggests: the kit is pinned to an exact
/// tag that Coach iOS also consumes, so a data refresh there is a kit release
/// plus a version bump in two apps, while this file is one copy into one
/// folder. `Resources/` is compiled into the app and the test bundle only --
/// never the widget, which has no use for menus. Moving it into the kit later
/// changes `bundled()` and nothing else.
///
/// **Lenient on purpose.** The file is hand-curated. A malformed chain, item
/// or rule is dropped rather than failing the whole list, a number that is not
/// a finite, non-negative number is read as not listed, and unknown keys are
/// ignored. Blank stays blank: an absent figure is nil, never zero.
struct RoadFoodCatalog: Decodable, Equatable {
    let chains: [RoadFoodChain]
    let snacks: [RoadFoodItem]
    let rules: [RoadFoodRule]

    enum CodingKeys: String, CodingKey { case chains, snacks, rules }

    init(chains: [RoadFoodChain], snacks: [RoadFoodItem], rules: [RoadFoodRule]) {
        self.chains = chains
        self.snacks = snacks
        self.rules = rules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A file with no chains array is not a Road Food file.
        chains = try c.decode([Lenient<RoadFoodChain>].self, forKey: .chains).compactMap(\.value)
        snacks = (try? c.decodeIfPresent([Lenient<RoadFoodItem>].self, forKey: .snacks))?
            .compactMap(\.value) ?? []
        rules = (try? c.decodeIfPresent([Lenient<RoadFoodRule>].self, forKey: .rules))?
            .compactMap(\.value) ?? []
    }

    static func decode(_ data: Data) throws -> RoadFoodCatalog {
        try JSONDecoder().decode(RoadFoodCatalog.self, from: data)
    }

    /// The snack categories in the order the file first uses them.
    var snackCategories: [String] {
        var seen = Set<String>()
        return snacks.compactMap(\.category).filter { seen.insert($0).inserted }
    }
}

/// Where a loaded catalogue came from, so a development build can say it is
/// showing made-up menus.
enum RoadFoodSource: Equatable {
    case bundled
    case developmentSample
}

extension RoadFoodCatalog {
    /// The shipped file, or -- in a DEBUG build only -- the sample with
    /// obviously fake names, or nil. A release build with no file has no Road
    /// Food: `FoodView` hides the entry point rather than offering an empty
    /// screen. The sample is compiled out of release builds entirely (see
    /// `RoadFoodSample.swift`), so nothing fake can ship.
    static func bundled(in bundle: Bundle = .main) -> (catalog: RoadFoodCatalog, source: RoadFoodSource)? {
        if let url = bundle.url(forResource: "road-food", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let catalog = try? decode(data), !catalog.chains.isEmpty || !catalog.snacks.isEmpty {
            return (catalog, .bundled)
        }
        #if DEBUG
        if let catalog = try? decode(Data(RoadFoodSample.json.utf8)) {
            return (catalog, .developmentSample)
        }
        #endif
        return nil
    }

    /// Read once per launch: the file is part of the app and cannot change
    /// while it runs.
    static let shared: (catalog: RoadFoodCatalog, source: RoadFoodSource)? = bundled()
}

struct RoadFoodChain: Decodable, Equatable, Identifiable, Hashable {
    let id: String
    let name: String
    /// Optional: "burgers", "mexican"... Matched against a rule's `kinds`.
    let kind: String?
    /// The date the chain's own document states about itself, as precise as
    /// the document is: "YYYY-MM-DD", or "YYYY-MM" where a chart names only a
    /// month. Nil where the document states no date at all, and then the
    /// warning falls back to `checkedOn`.
    let publishedOn: String?
    /// "YYYY-MM-DD", when the numbers were checked against the chain's page.
    let checkedOn: String?
    let source: String?
    let items: [RoadFoodItem]

    enum CodingKeys: String, CodingKey { case id, name, kind, publishedOn, checkedOn, source, items }

    init(id: String, name: String, kind: String? = nil, publishedOn: String? = nil,
         checkedOn: String? = nil, source: String? = nil, items: [RoadFoodItem]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.publishedOn = publishedOn
        self.checkedOn = checkedOn
        self.source = source
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "empty id")
        }
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? id
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        publishedOn = try? c.decodeIfPresent(String.self, forKey: .publishedOn)
        checkedOn = try? c.decodeIfPresent(String.self, forKey: .checkedOn)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        items = try c.decode([Lenient<RoadFoodItem>].self, forKey: .items).compactMap(\.value)
    }
}

/// One menu item or one gas-station product. Chain items and snacks share the
/// numeric field names; snacks add a category, a brand, a barcode and their
/// own check date and source.
struct RoadFoodItem: Decodable, Equatable, Identifiable, Hashable {
    let id: String
    let name: String
    let serving: String?
    let kcal: Double?
    let proteinG: Double?
    let fatG: Double?
    let carbsG: Double?
    let fiberG: Double?
    let saturatedFatG: Double?
    let sugarG: Double?
    let sodiumMg: Double?
    let modification: String?
    // Snacks only.
    let category: String?
    let brand: String?
    let barcode: String?
    let checkedOn: String?
    let source: String?

    enum CodingKeys: String, CodingKey {
        case id, name, serving, kcal, proteinG, fatG, carbsG, fiberG, saturatedFatG, sugarG, sodiumMg,
             modification, category, brand, barcode, checkedOn, source
    }

    init(id: String, name: String, serving: String? = nil,
         kcal: Double? = nil, proteinG: Double? = nil, fatG: Double? = nil, carbsG: Double? = nil,
         fiberG: Double? = nil, saturatedFatG: Double? = nil, sugarG: Double? = nil, sodiumMg: Double? = nil,
         modification: String? = nil, category: String? = nil, brand: String? = nil,
         barcode: String? = nil, checkedOn: String? = nil, source: String? = nil) {
        self.id = id
        self.name = name
        self.serving = serving
        self.kcal = kcal
        self.proteinG = proteinG
        self.fatG = fatG
        self.carbsG = carbsG
        self.fiberG = fiberG
        self.saturatedFatG = saturatedFatG
        self.sugarG = sugarG
        self.sodiumMg = sodiumMg
        self.modification = modification
        self.category = category
        self.brand = brand
        self.barcode = barcode
        self.checkedOn = checkedOn
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? name
        func text(_ key: CodingKeys) -> String? {
            guard let s = try? c.decodeIfPresent(String.self, forKey: key) else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        /// A finite, non-negative number, or nil -- `num` in road-food.js.
        func number(_ key: CodingKeys) -> Double? {
            guard let v = try? c.decodeIfPresent(Double.self, forKey: key), v.isFinite, v >= 0 else { return nil }
            return v
        }
        serving = text(.serving)
        kcal = number(.kcal)
        proteinG = number(.proteinG)
        fatG = number(.fatG)
        carbsG = number(.carbsG)
        fiberG = number(.fiberG)
        saturatedFatG = number(.saturatedFatG)
        sugarG = number(.sugarG)
        sodiumMg = number(.sodiumMg)
        modification = text(.modification)
        category = text(.category)
        brand = text(.brand)
        barcode = text(.barcode)
        checkedOn = text(.checkedOn)
        source = text(.source)
    }

    /// Brand and name for a product ("Jack Link's Original Beef Jerky"); the
    /// name alone for a menu item, whose chain is the screen's title.
    ///
    /// **The curated snack names already lead with their brand**, so
    /// prefixing it again printed "Jack Link's Jack Link's Original Beef
    /// Jerky" on every gas-station row -- seen on screen, not in a test.
    /// `RoadFoodRanking.entry(for:)` already dropped a repeated brand from a
    /// logged entry for the same reason; this is the same rule where the row
    /// is drawn. The brand is still carried when the name does not say it, so
    /// a future entry that leaves it out reads as it was meant to.
    var displayName: String {
        guard let brand, !brand.isEmpty,
              !name.localizedCaseInsensitiveContains(brand) else { return name }
        return "\(brand) \(name)"
    }
}

/// An ordering tip. A plain string in the file applies everywhere; an object
/// `{ "text", "kinds": [...] }` applies to chains of those kinds only.
struct RoadFoodRule: Decodable, Equatable, Hashable {
    let text: String
    /// Empty means everywhere.
    let kinds: [String]

    init(text: String, kinds: [String] = []) {
        self.text = text
        self.kinds = kinds
    }

    private enum CodingKeys: String, CodingKey { case text, kinds }

    init(from decoder: Decoder) throws {
        if let plain = try? decoder.singleValueContainer().decode(String.self) {
            self.init(text: plain)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let text = try c.decode(String.self, forKey: .text)
        self.init(text: text, kinds: (try? c.decodeIfPresent([String].self, forKey: .kinds)) ?? [])
    }
}

/// Decodes an element, or nothing, so one bad entry does not sink its array.
private struct Lenient<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
