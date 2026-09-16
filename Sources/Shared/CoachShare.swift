import Foundation
import LiftCore

/// Turns a stretch of this phone's log into one link, ready to email to a coach.
///
/// Nothing is uploaded. The whole log rides in the fragment of the URL — the
/// part after "#", which browsers never send to a server — so the numbers go
/// from this phone, through the mail provider, to the coach's browser, and the
/// site serving the coach app never sees them.
///
/// The wire format is specified in the coach app's SHARE-FORMAT.md and shared
/// with the Android and web versions of LIFT. All of them have to produce the
/// same bytes, which is why this file is deliberately literal.
enum CoachShare {

    static let coachURL = "https://www.dugcanlift.com/coach/"

    static let windowChoices = [4, 8, 12, 26]

    /// Past this, some mail apps wrap the link and quietly corrupt it.
    private static let riskyLinkLength = 16_000

    // MARK: - Settings

    /// Kept in AppStorage alongside the goals, for the same reason they are:
    /// single-valued, tiny, and needed before SwiftData has loaded anything.
    enum Settings {
        @AppStorageBacked("coachEmail", default: "") static var email: String
        @AppStorageBacked("coachLifterName", default: "") static var lifterName: String
        @AppStorageBacked("coachWeeks", default: 8) static var weeks: Int
        @AppStorageBacked("coachItemisedFood", default: false) static var itemisedFood: Bool
        /// Off unless the person turns it on. Times, distances and bests always
        /// go; a map of where someone runs is a different kind of thing to hand
        /// over, so it waits to be asked for.
        @AppStorageBacked("coachShareLastRoute", default: false) static var lastRoute: Bool

        /// Identifies this person to the coach app across every link they send.
        /// Generated once and never regenerated — a new id would land them in
        /// the coach's roster a second time, as a stranger with the same name.
        static var lifterID: String {
            let key = "coachLifterID"
            if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
                return existing
            }
            let fresh = String(UUID().uuidString.prefix(8))
            UserDefaults.standard.set(fresh, forKey: key)
            return fresh
        }

        static var isConfigured: Bool { !email.isEmpty }
    }

    // MARK: - Input

    /// Everything the payload needs, gathered by the view that has the queries.
    /// Passing a value in rather than fetching here keeps this testable and
    /// keeps SwiftData's main-actor rules where they belong.
    struct Snapshot {
        var days: [WorkoutDay]
        var food: [FoodEntry]
        var measurements: [BodyMeasurement]
        /// Steps per day, keyed "yyyy-MM-dd". Read from HealthKit at send
        /// time rather than stored, so it includes whatever a watch logged.
        var steps: [String: Int] = [:]
        /// Every run, walk and hike, not just the window's: bests are all-time.
        var outdoor: [OutdoorActivity] = []
        var goal: Goal?
        var unit: WeightUnit

        struct Goal {
            var calories: Int
            var proteinG: Int
            var fatG: Int
            var carbsG: Int
            var fiberG: Int
        }
    }

    // MARK: - Building the link

    static func buildLink(from snapshot: Snapshot, weeks: Int? = nil,
                          itemised: Bool? = nil, lastRoute: Bool? = nil) throws -> String {
        let payload = buildPayload(
            from: snapshot,
            weeks: weeks ?? Settings.weeks,
            itemised: itemised ?? Settings.itemisedFood,
            lastRoute: lastRoute ?? Settings.lastRoute
        )
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let packed = CompactEncoding.deflateRaw(json) else {
            return coachURL + "#1u" + CompactEncoding.base64URL(json)
        }
        return coachURL + "#1z" + CompactEncoding.base64URL(packed)
    }

    static func linkIsRisky(_ link: String) -> Bool { link.count > riskyLinkLength }

    /// Internal rather than private so a test can read the dictionary before
    /// it is deflated, for the same reason `setTuple` is.
    static func buildPayload(from snapshot: Snapshot, weeks: Int,
                             itemised: Bool, lastRoute: Bool) -> [String: Any] {
        let keys = lastDayKeys(count: weeks * 7)
        let offsets = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })

        var exerciseDict: [String] = []
        var foodDict: [String] = []
        var days: [String: [String: Any]] = [:]

        func day(_ key: String) -> [String: Any] { days[key] ?? [:] }

        func index(of value: String, in dict: inout [String]) -> Int {
            if let at = dict.firstIndex(of: value) { return at }
            dict.append(value)
            return dict.count - 1
        }

        for workoutDay in snapshot.days where offsets[workoutDay.dayKey] != nil {
            let exercises = workoutDay.orderedExercises.filter { !$0.sets.isEmpty }
            guard !exercises.isEmpty else { continue }

            var entry = day(workoutDay.dayKey)
            if !workoutDay.name.isEmpty { entry["n"] = workoutDay.name }
            entry["fo"] = workoutDay.focus.rawValue.uppercased()
            entry["w"] = exercises.map { exercise -> [Any] in
                let name = exercise.name.trimmingCharacters(in: .whitespaces)
                let equipment = (exercise.equipment ?? "").trimmingCharacters(in: .whitespaces)
                let dictIndex = index(of: "\(name)|\(equipment)", in: &exerciseDict)
                let sets = exercise.orderedSets.map { setTuple($0) }
                return [dictIndex, sets]
            }
            days[workoutDay.dayKey] = entry
        }

        if itemised {
            var detailsByDay: [String: [WireNutrientDetails?]] = [:]
            for food in snapshot.food where offsets[food.dayKey] != nil {
                var entry = day(food.dayKey)
                var list = entry["f"] as? [[Any]] ?? []
                let facts = food.nutrition
                // quantity is already baked into `nutrition`, so servings is 1
                // and the numbers below are what was actually eaten.
                list.append([
                    index(of: food.displayName, in: &foodDict), 1,
                    Int(facts.calories.rounded()), Int(facts.proteinG.rounded()),
                    Int(facts.fatG.rounded()), Int(facts.carbsG.rounded()),
                    Int((facts.fiberG ?? 0).rounded()), mealIndex(food.mealType),
                ])
                entry["f"] = list
                days[food.dayKey] = entry
                // One `fe` entry per `f` entry, in the same order, on the same
                // basis: this food's stored values are already what was eaten
                // and `f` says servings 1, so they go as they are.
                detailsByDay[food.dayKey, default: []].append(WireNutrientDetails(facts))
            }
            for (key, details) in detailsByDay {
                guard let rows = ShareNutrients.items(details), let wire = jsonValue(rows).map(shortDecimals) else { continue }
                var entry = day(key)
                entry["fe"] = wire
                days[key] = entry
            }
        } else {
            let byDay = Dictionary(grouping: snapshot.food.filter { offsets[$0.dayKey] != nil },
                                   by: \.dayKey)
            for (key, entries) in byDay {
                let totals = entries.totalNutrition
                var entry = day(key)
                entry["ft"] = [
                    Int(totals.calories.rounded()), Int(totals.proteinG.rounded()),
                    Int(totals.fatG.rounded()), Int(totals.carbsG.rounded()),
                    Int((totals.fiberG ?? 0).rounded()),
                ]
                days[key] = entry
            }
        }

        // `fx`: saturated fat, sugar and sodium for the day, over only the foods
        // that recorded each, with how many foods that is. Sent itemised or
        // not, so a coach never has to add `fe` up; absent when no food that
        // day recorded any of the three. Rounding is the kit's, so it matches
        // what LIFT Android and web send for the same day.
        let foodByDay = Dictionary(grouping: snapshot.food.filter { offsets[$0.dayKey] != nil }, by: \.dayKey)
        for (key, entries) in foodByDay {
            guard let wire = nutrientTotals(entries) else { continue }
            var entry = day(key)
            entry["fx"] = wire
            days[key] = entry
        }

        // Runs, walks and hikes, by the local day they started. A day with
        // nothing else on it is still a day.
        let outdoorByDay = Dictionary(
            grouping: snapshot.outdoor.filter { offsets[DayKey.make(from: $0.startedAt)] != nil },
            by: { DayKey.make(from: $0.startedAt) }
        )
        for (key, activities) in outdoorByDay {
            let wire = outdoorDay(activities)
            guard !wire.isEmpty else { continue }
            var entry = day(key)
            entry["o"] = wire
            days[key] = entry
        }

        for (key, count) in snapshot.steps where offsets[key] != nil {
            var entry = day(key)
            entry["st"] = count
            days[key] = entry
        }

        for measurement in snapshot.measurements where offsets[measurement.dayKey] != nil {
            guard let kg = measurement.weightKg else { continue }
            var entry = day(measurement.dayKey)
            entry["bw"] = round(kg * lbPerKg * 10) / 10
            days[measurement.dayKey] = entry
        }

        let dayArray = days
            .compactMap { key, value -> [String: Any]? in
                guard let offset = offsets[key], !value.isEmpty else { return nil }
                var withOffset = value
                withOffset["k"] = offset
                return withOffset
            }
            .sorted { ($0["k"] as? Int ?? 0) < ($1["k"] as? Int ?? 0) }

        let client: [String: Any] = [
            "i": Settings.lifterID,
            "n": Settings.lifterName.isEmpty ? "A LIFT user" : Settings.lifterName,
            // The wire is always pounds; this is only how they read it.
            "u": snapshot.unit == .kilograms ? "kg" : "lb",
            "p": "ios",
        ]

        var payload: [String: Any] = [
            "v": 1,
            "c": client,
            "r": keys.first ?? DayKey.make(from: .now),
            "t": DayKey.make(from: .now),
            "z": Int(Date.now.timeIntervalSince1970),
            "x": exerciseDict,
            "d": dayArray,
        ]

        if let goal = snapshot.goal {
            payload["g"] = [
                "c": goal.calories, "p": goal.proteinG, "f": goal.fatG,
                "cb": goal.carbsG, "fb": goal.fiberG,
            ]
        }
        if !foodDict.isEmpty { payload["fd"] = foodDict }
        // Bests are all-time, not the window. The route goes only when asked
        // for, trimmed so it never shows where someone starts and finishes.
        if let bests = outdoorBests(snapshot.outdoor) { payload["ob"] = bests }
        if lastRoute, let route = outdoorLastRoute(snapshot.outdoor) { payload["lr"] = route }

        return payload
    }

    /// A day's `fx`, or nil when none of its foods recorded saturated fat,
    /// sugar or sodium. `FoodEntry.nutrition` is already scaled to what was
    /// eaten, so each food counts at servings 1 — the product the kit expects.
    static func nutrientTotals(_ foods: [FoodEntry]) -> Any? {
        ShareNutrients.dayTotals(foods.map { (servings: 1, details: WireNutrientDetails($0.nutrition)) })
            .flatMap(jsonValue)
            .map(shortDecimals)
    }

    /// `JSONSerialization` writes a Double with seventeen significant digits,
    /// so the 14.7 `ShareNutrients` rounded to goes out as 14.699999999999999 —
    /// the same number to any decoder, but fifteen characters longer than what
    /// LIFT web and Android send, once per value, in a link that has a length
    /// budget. An `NSDecimalNumber` built from Swift's shortest representation
    /// is written as "14.7". Whole numbers become integers. Applied to `fx` and
    /// `fe` only; the shape itself is still the kit's encoding.
    static func shortDecimals(_ value: Any) -> Any {
        switch value {
        case let array as [Any]:
            return array.map(shortDecimals)
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            let double = number.doubleValue
            guard double.isFinite else { return number }
            if double == double.rounded(), abs(double) < 1e15 { return NSNumber(value: Int64(double)) }
            return NSDecimalNumber(string: "\(double)", locale: Locale(identifier: "en_US_POSIX"))
        default:
            return value
        }
    }

    // MARK: - Outdoor
    //
    // What goes out, how it is rounded, and how a route is trimmed, thinned
    // and encoded are all `LiftCore.OutdoorShare`'s — a port of LIFT web's
    // `outdoor.js`, pinned by fixtures that JavaScript wrote. This file only
    // maps its own storage in and turns the kit's tuples into the plain
    // arrays `JSONSerialization` writes. Nothing here re-derives a number.

    /// A day's `o`. The caller has already decided the activities are that day's.
    static func outdoorDay(_ activities: [OutdoorActivity]) -> [Any] {
        OutdoorShare.day(activities.map { shareActivity($0, withRoute: false) }).compactMap(jsonValue)
    }

    /// `ob`, or nil when nothing is finished.
    static func outdoorBests(_ activities: [OutdoorActivity]) -> [Any]? {
        OutdoorShare.bests(activities.map { shareActivity($0, withRoute: false) })
            .map { $0.compactMap(jsonValue) }
    }

    /// `lr`, or nil when no finished route survives the trim. Only this path
    /// decodes route points, which on a long history is thousands of them per
    /// activity — so a person who never opts in never pays for it.
    static func outdoorLastRoute(_ activities: [OutdoorActivity]) -> Any? {
        OutdoorShare.lastRoute(activities.map { shareActivity($0, withRoute: true) }).flatMap(jsonValue)
    }

    private static func shareActivity(_ activity: OutdoorActivity, withRoute: Bool) -> OutdoorShareActivity {
        let type: Int = switch activity.activityType {
        case .run:  0
        case .walk: 1
        case .hike: 2
        }
        return OutdoorShareActivity(
            type: type,
            startedAtEpochMs: epochMs(activity.startedAt),
            // Still recording means no end, and the kit never sends it.
            endedAtEpochMs: activity.endedAt.map(epochMs),
            distanceMeters: activity.distanceMeters,
            climbMeters: activity.elevationGainMeters,
            route: withRoute
                ? activity.routePoints.map { OutdoorShareCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
                : []
        )
    }

    /// Truncated to the millisecond, as `Date.now` is in JavaScript.
    private static func epochMs(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// The kit's wire types encode themselves as the tuples the format
    /// specifies (a missing best is an explicit null). Going through that
    /// encoding, rather than rebuilding the arrays here, keeps one definition
    /// of the shape.
    private static func jsonValue<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// `[weight, reps, rpe, seconds, metres, flags]` with trailing blanks
    /// dropped, so an ordinary set costs eleven characters instead of sixty.
    ///
    /// Positions 4 and 5 were hard-coded null while this app had no way to
    /// record a time or a distance. It has since schema V6, so they carry the
    /// real values — otherwise a coach would silently lose every interval and
    /// sled push an iPhone client logged, while seeing the Android ones.
    /// Internal rather than private so a test can assert the tuple directly;
    /// the link it ends up in is deflated, and round-tripping that would test
    /// the codec rather than this.
    static func setTuple(_ set: SetEntry) -> [Any] {
        let weight = set.weightKg > 0 ? round(set.weightKg * lbPerKg * 10) / 10 : nil
        let flags = set.isWarmup ? 1 : 0

        var values: [Any?] = [
            weight, set.reps > 0 ? set.reps : nil, set.rpe,
            set.durationSec, set.distanceMeters, flags,
        ]
        while let last = values.last, last == nil || (last as? Int) == 0 {
            values.removeLast()
        }
        return values.map { $0 ?? NSNull() }
    }

    private static func mealIndex(_ meal: MealType) -> Int {
        switch meal {
        case .breakfast: 0
        case .lunch:     1
        case .dinner:    2
        case .snack:     3
        }
    }

    // MARK: - The part the coach reads without tapping

    static func weekSummary(from snapshot: Snapshot) -> String {
        let week = Set(lastDayKeys(count: 7))
        let trainingDays = snapshot.days.filter { week.contains($0.dayKey) && !$0.exercises.isEmpty }
        let sets = trainingDays.reduce(0) { $0 + $1.totalSetCount }
        let volumeLb = trainingDays.reduce(0.0) { $0 + $1.totalVolumeKg } * lbPerKg

        var lines = ["Last 7 days"]
        lines.append(
            "Training   \(trainingDays.count) session\(trainingDays.count == 1 ? "" : "s") · \(sets) sets"
            + (volumeLb > 0 ? " · \(formatted(Int(volumeLb.rounded()))) lb" : "")
        )

        let weekFood = snapshot.food.filter { week.contains($0.dayKey) }
        let loggedDays = Set(weekFood.map(\.dayKey)).count
        if loggedDays == 0 {
            lines.append("Fuel       nothing logged this week")
        } else {
            let totals = weekFood.totalNutrition
            let kcal = Int((totals.calories / Double(loggedDays)).rounded())
            let protein = Int((totals.proteinG / Double(loggedDays)).rounded())
            var line = "Fuel       \(formatted(kcal)) kcal · \(protein) g protein"
            if let goal = snapshot.goal {
                line += "  (goal \(formatted(goal.calories)) · \(goal.proteinG))"
            }
            line += "  over \(loggedDays) logged day\(loggedDays == 1 ? "" : "s")"
            lines.append(line)
        }

        let weekSteps = lastDayKeys(count: 7).compactMap { snapshot.steps[$0] }
        if !weekSteps.isEmpty {
            let average = weekSteps.reduce(0, +) / weekSteps.count
            lines.append("Steps      \(formatted(average)) a day"
                         + "  over \(weekSteps.count) day\(weekSteps.count == 1 ? "" : "s")")
        }

        if let latest = snapshot.measurements
            .filter({ $0.weightKg != nil })
            .max(by: { $0.recordedAt < $1.recordedAt }),
           let kg = latest.weightKg {
            let shown = snapshot.unit.fromKilograms(kg)
            lines.append("Weight     \(String(format: "%.1f", shown)) \(snapshot.unit.abbreviation)"
                         + " on \(shortDate(latest.dayKey))")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - The email

    static var subject: String {
        let name = Settings.lifterName.isEmpty ? "your client" : Settings.lifterName
        return "LIFT log from \(name) — \(shortDate(DayKey.make(from: .now)))"
    }

    static func htmlBody(link: String, summary: String, weeks: Int) -> String {
        let name = Settings.lifterName.isEmpty ? "the" : escape(firstName) + "'s"
        return """
        <p><a href="\(link)" style="display:inline-block;padding:12px 22px;\
        background:#c1442c;color:#f7f1e8;text-decoration:none;border-radius:999px;\
        font-family:-apple-system,sans-serif;font-weight:600">Open \(name) log</a></p>
        <pre style="font-family:-apple-system,sans-serif;font-size:14px">\(escape(summary))</pre>
        <p style="color:#777;font-size:12px">Covers the last \(weeks) weeks. Sent from LIFT.<br>
        If the button does nothing, copy this link:<br>\(escape(link))</p>
        """
    }

    static func plainBody(link: String, summary: String, weeks: Int) -> String {
        """
        Open the log:
        \(link)

        \(summary)

        Covers the last \(weeks) weeks. Sent from LIFT.
        """
    }

    private static var firstName: String {
        Settings.lifterName.split(separator: " ").first.map(String.init) ?? "the"
    }

    // MARK: - Encoding
    //
    // Raw DEFLATE plus base64url now come from `CompactEncoding` (LiftCore),
    // not a private copy here — the encoder that actually produces the links
    // a JavaScript app reads is this file, so it must go through the same
    // plumbing `CompactEncoding`'s decoder-side callers rely on, or the
    // "can never drift" guarantee in `CompactEncoding`'s doc comment is
    // hollow.

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Dates and numbers

    private static let lbPerKg = 2.2046226218

    private static func lastDayKeys(count: Int) -> [String] {
        let calendar = Calendar.current
        let today = Date.now
        return (0..<count).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: today).map { DayKey.make(from: $0) }
        }
    }

    private static func shortDate(_ key: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: key) else { return key }
        let display = DateFormatter()
        display.dateFormat = "MMM d"
        return display.string(from: date)
    }

    private static func formatted(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

/// A property wrapper for the handful of settings that are read outside a
/// SwiftUI view, where `@AppStorage` cannot be used.
@propertyWrapper
struct AppStorageBacked<Value> {
    private let key: String
    private let defaultValue: Value

    init(_ key: String, default defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: Value {
        get { UserDefaults.standard.object(forKey: key) as? Value ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
