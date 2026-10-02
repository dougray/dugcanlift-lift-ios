import Foundation
import LiftCore

/// Road Food's rules: what at this chain fits what is left of today, how old
/// the numbers are, which ordering tips apply, and the food entry an item
/// logs as. A value type with no view in it, because these decide what a
/// person is told they can eat; `RoadFoodRankingTests` pins them.
///
/// A port of LIFT web's `lift/road-food.js` (dugcanlift-site), function for
/// function, and its tests are ported in `RoadFoodRankingTests`. Where the
/// two differ it is said below and why.
///
/// Ranking, as the spec has it:
///
/// 1. **Fits**: calories at or under what is left today. Below those, a
///    separate "A little over" group holds items no more than 10% over.
///    Anything past that is not shown at all -- hidden, not greyed.
/// 2. Within each group, **protein per 100 kcal**, highest first.
/// 3. Ties go to the **lower sodium**. Sodium is otherwise only shown, never
///    scored, and nothing colours, badges or warns about it.
///
/// With no goal there is nothing to fit, so every item is ranked by protein
/// per 100 kcal alone, and the screen says so.
///
/// **Blank stays blank.** An item whose protein is not listed has no protein
/// density, not a density of zero: it ranks after every item whose protein is
/// known. Unknown sodium loses a tie to any known sodium rather than winning
/// it as a zero. An item with no calorie figure cannot be said to fit, so it
/// is left out when there is a goal and ranked last when there is not.
///
/// A coach's road picks (`withPicks`) sort to the top of a group and change
/// nothing else: not the order underneath them, not which items fit, not what
/// is hidden. See `coach/PLAN-FORMAT.md` "Road picks".
enum RoadFoodRanking {

    enum Mode: Equatable { case goal, noGoal }

    struct Ranked: Equatable {
        let mode: Mode
        /// At or under what is left, or every item with no goal.
        let fits: [RoadFoodItem]
        /// More than what is left, but no more than 10% over. Empty with no goal.
        let over: [RoadFoodItem]
        /// The coach's picks that are actually on this screen, by id. Empty
        /// until `withPicks` floats them, and an id this copy of the file does
        /// not have is never in it -- nothing counts a row nobody can see.
        let picked: Set<String>

        init(mode: Mode, fits: [RoadFoodItem], over: [RoadFoodItem], picked: Set<String> = []) {
            self.mode = mode
            self.fits = fits
            self.over = over
            self.picked = picked
        }

        func isPicked(_ item: RoadFoodItem) -> Bool { picked.contains(item.id) }
    }

    /// Grams of protein per 100 kcal, or nil when it cannot honestly be said.
    /// Zero calories and zero protein is 0 (a diet drink); zero calories with
    /// protein is infinity, which ranks it first, as it should.
    static func proteinPer100(_ item: RoadFoodItem) -> Double? {
        guard let kcal = item.kcal, let protein = item.proteinG else { return nil }
        if kcal == 0 { return protein == 0 ? 0 : .infinity }
        return protein / kcal * 100
    }

    /// Known before unknown, then higher density, then lower sodium, then
    /// name, so the order is the same on every run and every device.
    static func areInOrder(_ a: RoadFoodItem, _ b: RoadFoodItem) -> Bool {
        let da = proteinPer100(a), db = proteinPer100(b)
        if (da == nil) != (db == nil) { return da != nil }
        if let da, let db, da != db { return da > db }
        let sa = a.sodiumMg, sb = b.sodiumMg
        if (sa == nil) != (sb == nil) { return sa != nil }
        if let sa, let sb, sa != sb { return sa < sb }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// `remainingCalories` is what is left of today, nil with no goal set.
    ///
    /// The 10% line is `kcal x 10 <= left x 11`, so 704 over 640 is in and
    /// 705 is out, with no `x 1.1` floating-point edge (30 x 1.1 is
    /// 33.000000000000004). A day already past its calories has nothing
    /// left, and 10% of nothing is nothing: only a zero-calorie item fits.
    static func rank(_ items: [RoadFoodItem], remainingCalories: Double?) -> Ranked {
        guard let remainingCalories, remainingCalories.isFinite else {
            return Ranked(mode: .noGoal, fits: items.sorted(by: areInOrder), over: [])
        }
        let left = max(remainingCalories, 0)
        var fits: [RoadFoodItem] = []
        var over: [RoadFoodItem] = []
        for item in items {
            guard let kcal = item.kcal else { continue }
            if kcal <= left {
                fits.append(item)
            } else if kcal * 10 <= left * 11 {
                over.append(item)
            }
        }
        return Ranked(mode: .goal, fits: fits.sorted(by: areInOrder), over: over.sorted(by: areInOrder))
    }

    // MARK: - A coach's picks

    /// A ranked result with the coach's picks floated to the top of each
    /// group, and nothing else changed: not the order underneath them, not
    /// which items fit, not what is hidden. A pick is an opinion sitting
    /// beside the numbers, never in front of them, so a pick that is "a little
    /// over" stays in the little-over group where the arithmetic put it, and
    /// one more than 10% over stays hidden -- picked or not.
    ///
    /// An id this copy of `road-food.json` does not have is **skipped,
    /// silently**: the coach's file and this one are two builds updated at
    /// different times, and an item withdrawn since the plan was sent must
    /// leave no row, no gap and no error. It is not counted either, so no card
    /// promises a row that is not there.
    static func withPicks(_ ranked: Ranked, ids: [String]) -> Ranked {
        guard !ids.isEmpty else { return ranked }
        let wanted = Set(ids)
        let onScreen = Set((ranked.fits + ranked.over).map(\.id)).intersection(wanted)
        guard !onScreen.isEmpty else { return ranked }
        return Ranked(mode: ranked.mode,
                      fits: pickedFirst(ranked.fits, onScreen),
                      over: pickedFirst(ranked.over, onScreen),
                      picked: onScreen)
    }

    /// A stable partition: the picked ones first, each part in exactly the
    /// order it already had. Sorting on a "picked" key would do the same thing
    /// today and is not written that way on purpose -- the promise is that the
    /// nutrition order is untouched, and a partition cannot quietly stop
    /// keeping it.
    private static func pickedFirst(_ list: [RoadFoodItem], _ picked: Set<String>) -> [RoadFoodItem] {
        list.filter { picked.contains($0.id) } + list.filter { !picked.contains($0.id) }
    }

    /// How many of `items` are picked -- for a tile, which draws no list.
    static func pickCount(_ items: [RoadFoodItem], ids: [String]) -> Int {
        guard !ids.isEmpty else { return 0 }
        let wanted = Set(ids)
        return Set(items.map(\.id)).intersection(wanted).count
    }

    // MARK: - How old the numbers are

    /// A document's own date as a calendar day, or nil. `publishedOn` is only
    /// as precise as the document is, so it may be "2022-11" where the chart
    /// says only "NOVEMBER 2022"; a month-only date is read as the first of
    /// that month, which can only make a document look older, never fresher.
    static func docDay(_ text: String?) -> CalendarDay? {
        guard let text else { return nil }
        return CalendarDay(text.count == 7 ? text + "-01" : text)
    }

    /// The date the "these numbers are old" warning keys off: the document's
    /// own date when the chain states one, and the day a person read it when
    /// it does not. Different facts -- `publishedOn` is when the chain wrote
    /// the chart, `checkedOn` is when someone read it -- and only the first
    /// can say a chart is from 2021.
    static func ageDate(_ chain: RoadFoodChain?) -> String? {
        chain?.publishedOn ?? chain?.checkedOn
    }

    /// Whether `day` is more than six calendar months before `today`. Calendar
    /// months, not 182 days: "six months old" is what the screen says, so it
    /// is what gets measured. `day` is "YYYY-MM-DD", or "YYYY-MM" for a
    /// document that names only a month. 31 March plus six months is 30
    /// September, clamped to the month's end rather than rolled into October.
    /// Nil when either date is missing or not a real date, which the screen
    /// also says.
    ///
    /// Plain year/month/day arithmetic, with no `Date` and so no time zone:
    /// both are calendar dates already.
    static func isStale(checkedOn: String?, today: String) -> Bool? {
        guard let checked = docDay(checkedOn), let now = CalendarDay(today) else { return nil }
        let monthIndex = checked.month - 1 + 6
        let year = checked.year + monthIndex / 12
        let month = monthIndex % 12 + 1
        let limit = CalendarDay(year: year, month: month,
                                day: min(checked.day, CalendarDay.daysIn(month: month, year: year)))
        return now > limit
    }

    // MARK: - Ordering rules

    /// The ordering tips for one chain: every rule with no kinds, plus the
    /// ones whose kinds include `kind`.
    static func rulesFor(_ rules: [RoadFoodRule], kind: String?) -> [String] {
        rules.compactMap { rule in
            let text = rule.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if rule.kinds.isEmpty { return text }
            guard let kind, rule.kinds.contains(kind) else { return nil }
            return text
        }
    }

    /// The gas station's tips: only rules written for it (kinds include
    /// "snacks"). The plain rules are about ordering at a counter -- "grilled
    /// over fried" means nothing in front of a jerky rack.
    static func gasStationRules(_ rules: [RoadFoodRule]) -> [String] {
        rulesFor(rules.filter { !$0.kinds.isEmpty }, kind: "snacks")
    }

    // MARK: - The chain picker

    /// Chains with the recently used ones first, most recent first, then the
    /// rest by name. Unknown ids in `recent` are ignored.
    static func orderChains(_ chains: [RoadFoodChain], recent: [String])
        -> (recent: [RoadFoodChain], rest: [RoadFoodChain]) {
        var byID: [String: RoadFoodChain] = [:]
        for chain in chains where byID[chain.id] == nil { byID[chain.id] = chain }
        var seen = Set<String>()
        var first: [RoadFoodChain] = []
        for id in recent {
            if let chain = byID[id], seen.insert(id).inserted { first.append(chain) }
        }
        let rest = chains.filter { !seen.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (first, rest)
    }

    /// `recent` with `id` moved to the front, kept to `max`.
    static func remember(_ recent: [String], id: String, max: Int = 5) -> [String] {
        Array(([id] + recent.filter { $0 != id }).prefix(max))
    }

    /// The recent list as `@AppStorage` keeps it: ids joined by commas. Ids
    /// are slugs (`[a-z0-9-]`), so a comma never appears in one.
    static func decodeRecent(_ stored: String) -> [String] {
        stored.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    static func encodeRecent(_ ids: [String]) -> String {
        ids.joined(separator: ",")
    }

    // MARK: - Logging

    /// Why an item cannot be logged, in words, or nil when it can.
    ///
    /// **Differs from web**, which logs anything with a calorie figure and
    /// leaves any other missing macro off the entry. A `FoodEntry` cannot
    /// leave one off: `NutritionFacts` holds calories, protein, carbs and fat
    /// as plain numbers, so a missing one would be written as zero -- a
    /// lifter's protein under-counted without a word. The kit's validator
    /// requires all four in the real file, so this only ever stops a
    /// malformed entry, and it says which figure is missing.
    static func cannotLogReason(_ item: RoadFoodItem) -> String? {
        let missing = [("calories", item.kcal), ("protein", item.proteinG),
                       ("carbs", item.carbsG), ("fat", item.fatG)]
            .filter { $0.1 == nil }
            .map(\.0)
        guard !missing.isEmpty else { return nil }
        return "Can't be logged: \(ListFormatter.localizedString(byJoining: missing)) not listed"
    }

    /// The `foodRefID` namespace. Stable item ids are what a coach's "road
    /// picks" will name one day; the watch cannot resolve one, so it is kept
    /// out of the watch's recent foods (`WatchSyncReceiver.makeSnapshot`).
    static let foodRefPrefix = "road:"

    /// An ordinary food entry for one item: one serving, the item's own
    /// numbers as the totals. Macros are rounded to whole numbers, saturated
    /// fat and sugar to one decimal and sodium to whole milligrams, as web's
    /// `entryFor` does. Fibre, saturated fat, sugar and sodium the item does
    /// not list are nil, never zero, and a listed zero is kept as zero. Nil
    /// when `cannotLogReason` says it cannot be logged.
    ///
    /// A menu item is named "Grilled Chicken Sandwich (Wendy's)", exactly as
    /// web names it, so a coach reads the same line whichever app sent it. A
    /// gas-station product carries its brand in `brand`, the way a scanned
    /// packaged food does.
    static func entry(for item: RoadFoodItem, chainName: String?, mealType: MealType,
                      loggedAt: Date = .now) -> FoodEntry? {
        guard cannotLogReason(item) == nil,
              let kcal = item.kcal, let protein = item.proteinG,
              let carbs = item.carbsG, let fat = item.fatG else { return nil }
        let tenths = { (v: Double) in (v * 10).rounded() / 10 }
        let nutrition = NutritionFacts(
            calories: kcal.rounded(),
            proteinG: protein.rounded(),
            carbsG: carbs.rounded(),
            fatG: fat.rounded(),
            fiberG: item.fiberG.map { $0.rounded() },
            sugarG: item.sugarG.map(tenths),
            sodiumMg: item.sodiumMg.map { $0.rounded() },
            saturatedFatG: item.saturatedFatG.map(tenths)
        )
        let serving = servingParts(item.serving)
        let name = chainName.map { "\(item.name) (\($0))" } ?? item.name
        return FoodEntry(
            foodRefID: foodRefPrefix + item.id,
            name: name,
            // The curated snack names already lead with the brand (LIFT web shows
            // only the name), so carrying it again would print it twice.
            brand: chainName == nil ? item.brand.flatMap { item.name.localizedCaseInsensitiveContains($0) ? nil : $0 } : nil,
            quantity: serving.quantity,
            servingUnit: serving.unit,
            nutrition: nutrition,
            mealType: mealType,
            loggedAt: loggedAt
        )
    }

    /// "2 patties" as quantity 2 and unit "patties", so Food's amount line
    /// (`quantity` then `servingUnit`) reads "2 patties" rather than
    /// "1 2 patties". Display only: the entry's nutrition is already the whole
    /// serving and is never scaled by this. A serving with no leading number
    /// ("a bowl", or none) is one of itself.
    static func servingParts(_ serving: String?) -> (quantity: Double, unit: String) {
        guard let serving, !serving.isEmpty else { return (1, "serving") }
        let pieces = serving.split(separator: " ", maxSplits: 1)
        if pieces.count == 2, let n = Double(pieces[0]), n.isFinite, n > 0 {
            return (n, String(pieces[1]))
        }
        return (1, serving)
    }

    // MARK: - Display

    /// "Protein bar" from "protein-bar" (the kit's slugs) or "protein bars".
    static func categoryLabel(_ category: String) -> String {
        let words = category.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// A document's own date, printed no more precisely than the document
    /// wrote it: "Mar 29, 2021" for a chart that gives a day, "Nov 2022" for
    /// one that names only a month. Nil when it is not a date.
    static func publishedText(_ key: String?, locale: Locale = .current) -> String? {
        guard let key, let day = docDay(key) else { return nil }
        guard key.count == 7 else { return dateText(key, locale: locale) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: 1, hour: 12))
        else { return nil }
        var style = Date.FormatStyle().year().month(.abbreviated).locale(locale)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// "Sep 20, 2026" for a "YYYY-MM-DD", or nil when it is not a date.
    static func dateText(_ key: String?, locale: Locale = .current) -> String? {
        guard let day = CalendarDay(key) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))
        else { return nil }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}

/// A "YYYY-MM-DD" as three numbers, rejecting anything that is not a real day
/// (a February 30th is not a date, as web's `parseDay` says).
struct CalendarDay: Comparable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init?(_ text: String?) {
        guard let text, text.count == 10 else { return nil }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1, d <= Self.daysIn(month: m, year: y) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    static func < (a: CalendarDay, b: CalendarDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}
