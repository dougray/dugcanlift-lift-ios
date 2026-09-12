import Foundation
import Compression
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
                          itemised: Bool? = nil) throws -> String {
        let payload = buildPayload(
            from: snapshot,
            weeks: weeks ?? Settings.weeks,
            itemised: itemised ?? Settings.itemisedFood
        )
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let packed = deflateRaw(json) else {
            return coachURL + "#1u" + base64URL(json)
        }
        return coachURL + "#1z" + base64URL(packed)
    }

    static func linkIsRisky(_ link: String) -> Bool { link.count > riskyLinkLength }

    private static func buildPayload(from snapshot: Snapshot, weeks: Int,
                                     itemised: Bool) -> [String: Any] {
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

        return payload
    }

    /// `[weight, reps, rpe, seconds, metres, flags]` with trailing blanks
    /// dropped, so an ordinary set costs eleven characters instead of sixty.
    /// iOS records no time or distance, so those two are always null here —
    /// the positions stay because the Android app fills them.
    private static func setTuple(_ set: SetEntry) -> [Any] {
        let weight = set.weightKg > 0 ? round(set.weightKg * lbPerKg * 10) / 10 : nil
        let flags = set.isWarmup ? 1 : 0

        var values: [Any?] = [
            weight, set.reps > 0 ? set.reps : nil, set.rpe, nil, nil, flags,
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

    /// Raw DEFLATE, no zlib wrapper. `COMPRESSION_ZLIB` is Apple's name for
    /// RFC 1951, which is the same bytes as the browser's
    /// CompressionStream('deflate-raw') and Android's Deflater(nowrap: true).
    /// That equivalence is the only reason one decoder can read all three.
    private static func deflateRaw(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = max(data.count, 128)
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }

        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(destination, capacity, base, data.count,
                                             nil, COMPRESSION_ZLIB)
        }
        // Zero means it did not fit, which for a log this size means something
        // is wrong. The caller falls back to sending it uncompressed.
        guard written > 0 else { return nil }
        return Data(bytes: destination, count: written)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

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
