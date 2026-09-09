import Foundation
import SwiftData

/// Reads and writes the backup file the user saves from Settings.
///
/// The format is documented in the site repo at `coach/BACKUP-FORMAT.md` and is
/// shared with the web and Android versions of LIFT. With no account and no
/// server, a file the user keeps is the only way a log survives a reinstall,
/// and the only way it moves to another platform.
///
/// This app's model is richer than the common shape in places and poorer in
/// others, so anything that does not fit travels under `ext.ios`, keyed by the
/// id of the record it belongs to. The same rule applies in reverse: an `ext`
/// block belonging to another platform is read in, held, and written back out
/// untouched, so a round trip through here cannot quietly strip what an Android
/// phone recorded.
enum BackupStore {

    static let version = 1
    static let app = "lift"
    static let lbPerKg = 2.2046226218

    struct RestoreResult {
        let added: Int
        let ok: Bool
        let problem: String?
    }

    // MARK: - Building

    static func build(context: ModelContext, keepingForeignExt foreign: [String: Any] = [:]) throws -> Data {
        let days = try context.fetch(FetchDescriptor<WorkoutDay>())
        let food = try context.fetch(FetchDescriptor<FoodEntry>())
        let measurements = try context.fetch(FetchDescriptor<BodyMeasurement>())

        var data: [String: Any] = [:]
        var iosFood: [String: Any] = [:]
        var iosDays: [String: Any] = [:]
        var iosExercises: [String: Any] = [:]
        var iosSets: [String: Any] = [:]

        // ---- food ----
        data["food"] = food.map { entry -> [String: Any] in
            let facts = entry.nutrition
            let key = entry.id.uuidString

            var extras: [String: Any] = [
                "servingUnit": entry.servingUnit,
                "foodRefID": entry.foodRefID
            ]
            entry.brand.map { extras["brand"] = $0 }
            entry.servingGrams.map { extras["servingGrams"] = $0 }
            entry.amountGrams.map { extras["amountGrams"] = $0 }
            facts.sugarG.map { extras["sugarG"] = $0 }
            facts.sodiumMg.map { extras["sodiumMg"] = $0 }
            entry.healthKitUUID.map { extras["healthKitUUID"] = $0.uuidString }
            iosFood[key] = extras

            return [
                "id": key,
                "name": entry.name,
                "servings": entry.quantity,
                "calories": Int(facts.calories.rounded()),
                "proteinG": Int(facts.proteinG.rounded()),
                "fatG": Int(facts.fatG.rounded()),
                "carbsG": Int(facts.carbsG.rounded()),
                "fiberG": Int((facts.fiberG ?? 0).rounded()),
                "date": entry.dayKey,
                "loggedAt": Int(entry.loggedAt.timeIntervalSince1970 * 1000),
                "meal": entry.mealType.rawValue.uppercased()
            ]
        }

        // ---- workouts ----
        data["workouts"] = days.map { day -> [String: Any] in
            let dayKey = day.id.uuidString
            var dayExtras: [String: Any] = ["focus": day.focus.rawValue]
            day.liveStartedAt.map { dayExtras["liveStartedAt"] = Int($0.timeIntervalSince1970 * 1000) }
            day.liveEndedAt.map { dayExtras["liveEndedAt"] = Int($0.timeIntervalSince1970 * 1000) }
            day.healthKitUUID.map { dayExtras["healthKitUUID"] = $0.uuidString }
            iosDays[dayKey] = dayExtras

            let exercises = day.orderedExercises.map { exercise -> [String: Any] in
                let exKey = exercise.id.uuidString
                var exExtras: [String: Any] = [
                    "exerciseRefID": exercise.exerciseRefID,
                    "orderIndex": exercise.orderIndex
                ]
                exercise.primaryMuscle.map { exExtras["primaryMuscle"] = $0 }
                iosExercises[exKey] = exExtras

                let sets = exercise.orderedSets.map { set -> [String: Any] in
                    let setKey = set.id.uuidString
                    var setExtras: [String: Any] = [
                        "orderIndex": set.orderIndex,
                        "isWarmup": set.isWarmup
                    ]
                    set.completedAt.map { setExtras["completedAt"] = Int($0.timeIntervalSince1970 * 1000) }
                    iosSets[setKey] = setExtras

                    var payload: [String: Any] = ["id": setKey, "reps": set.reps]
                    if set.weightKg > 0 {
                        payload["weightLb"] = (set.weightKg * lbPerKg * 10).rounded() / 10
                    }
                    set.rpe.map { payload["rpe"] = $0 }
                    return payload
                }

                return [
                    "id": exKey,
                    "name": exercise.name,
                    "equipment": exercise.equipment ?? "",
                    "note": "",
                    "sets": sets
                ]
            }

            return [
                "id": dayKey,
                "date": day.dayKey,
                "name": day.name,
                "note": "",
                "startedAt": Int(day.date.timeIntervalSince1970 * 1000),
                "exercises": exercises
            ]
        }

        // ---- bodyweight ----
        // The common shape is a flat date → pounds map. The richer record, with
        // body fat and the HealthKit link, rides in ext.
        var weights: [String: Double] = [:]
        var iosMeasurements: [[String: Any]] = []
        for measurement in measurements {
            if let kg = measurement.weightKg {
                weights[measurement.dayKey] = (kg * lbPerKg * 10).rounded() / 10
            }
            var record: [String: Any] = [
                "id": measurement.id.uuidString,
                "dayKey": measurement.dayKey,
                "recordedAt": Int(measurement.recordedAt.timeIntervalSince1970 * 1000)
            ]
            measurement.weightKg.map { record["weightKg"] = $0 }
            measurement.bodyFatPercent.map { record["bodyFatPercent"] = $0 }
            measurement.healthKitUUID.map { record["healthKitUUID"] = $0.uuidString }
            iosMeasurements.append(record)
        }
        data["weights"] = weights

        // ---- coach, goal and settings ----
        // All AppStorage rather than SwiftData: single-valued, tiny, and needed
        // before the store has loaded anything.
        data["coach"] = [
            "email": CoachShare.Settings.email,
            "you": CoachShare.Settings.lifterName,
            "id": CoachShare.Settings.lifterID,
            "weeks": CoachShare.Settings.weeks,
            "itemised": CoachShare.Settings.itemisedFood
        ]

        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "goalIsSet") {
            data["goal"] = [
                "calories": Int(defaults.double(forKey: "goalCalories").rounded()),
                "proteinG": Int(defaults.double(forKey: "goalProtein").rounded()),
                "fatG": Int(defaults.double(forKey: "goalFat").rounded()),
                "carbsG": Int(defaults.double(forKey: "goalCarbs").rounded()),
                "fiberG": Int(defaults.double(forKey: "goalFiber").rounded())
            ]
        }

        // AppStorage defaults are not written to UserDefaults until something
        // changes them, so `double(forKey:)` answers 0 for a step goal the user
        // has simply never edited. Fall back to the same default the UI shows.
        let stepGoal = defaults.object(forKey: "goalSteps") as? Double ?? 10_000
        data["settings"] = [
            "stepGoal": Int(stepGoal),
            "weightUnit": defaults.string(forKey: "weightUnit") ?? WeightUnit.pounds.rawValue
        ]

        var ios: [String: Any] = [:]
        if !iosFood.isEmpty { ios["food"] = iosFood }
        if !iosDays.isEmpty { ios["workouts"] = iosDays }
        if !iosExercises.isEmpty { ios["exercises"] = iosExercises }
        if !iosSets.isEmpty { ios["sets"] = iosSets }
        if !iosMeasurements.isEmpty { ios["measurements"] = iosMeasurements }

        // Anything another platform left behind is carried through untouched.
        var ext = foreign.isEmpty ? storedForeignExt() : foreign
        ext["ios"] = ios

        let root: [String: Any] = [
            "v": version,
            "app": app,
            "saved": Self.todayKey(),
            "data": data,
            "ext": ext
        ]

        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Restoring

    static func restore(context: ModelContext, from data: Data) -> RestoreResult {
        guard
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            root["app"] as? String == app,
            let payload = root["data"] as? [String: Any]
        else {
            return RestoreResult(added: 0, ok: false, problem: "That file isn't a LIFT backup.")
        }

        let ext = root["ext"] as? [String: Any] ?? [:]
        let ios = ext["ios"] as? [String: Any] ?? [:]
        let iosFood = ios["food"] as? [String: Any] ?? [:]
        let iosDays = ios["workouts"] as? [String: Any] ?? [:]
        let iosExercises = ios["exercises"] as? [String: Any] ?? [:]
        let iosSets = ios["sets"] as? [String: Any] ?? [:]

        var added = 0

        // Existing ids, so a restore only ever fills gaps.
        let existingFood = Set((try? context.fetch(FetchDescriptor<FoodEntry>()))?.map(\.id) ?? [])
        let existingDays = Set((try? context.fetch(FetchDescriptor<WorkoutDay>()))?.map(\.id) ?? [])

        for raw in payload["food"] as? [[String: Any]] ?? [] {
            guard let id = uuid(raw["id"]), !existingFood.contains(id) else { continue }
            let extras = iosFood[raw["id"] as? String ?? ""] as? [String: Any] ?? [:]

            let entry = FoodEntry(
                foodRefID: extras["foodRefID"] as? String ?? "",
                name: raw["name"] as? String ?? "",
                brand: extras["brand"] as? String,
                quantity: double(raw["servings"]) ?? 1,
                servingUnit: extras["servingUnit"] as? String ?? "serving",
                servingGrams: double(extras["servingGrams"]),
                amountGrams: double(extras["amountGrams"]),
                nutrition: NutritionFacts(
                    calories: double(raw["calories"]) ?? 0,
                    proteinG: double(raw["proteinG"]) ?? 0,
                    carbsG: double(raw["carbsG"]) ?? 0,
                    fatG: double(raw["fatG"]) ?? 0,
                    fiberG: double(raw["fiberG"]),
                    sugarG: double(extras["sugarG"]),
                    sodiumMg: double(extras["sodiumMg"])
                ),
                mealType: MealType(rawValue: (raw["meal"] as? String ?? "snack").lowercased()) ?? .snack,
                loggedAt: date(raw["loggedAt"]) ?? .now
            )
            entry.id = id
            // The init derives dayKey from loggedAt; the file's own value wins,
            // so a day logged either side of midnight stays where it was put.
            if let dayKey = raw["date"] as? String, !dayKey.isEmpty { entry.dayKey = dayKey }
            entry.healthKitUUID = uuid(extras["healthKitUUID"])
            context.insert(entry)
            added += 1
        }

        for raw in payload["workouts"] as? [[String: Any]] ?? [] {
            guard let id = uuid(raw["id"]), !existingDays.contains(id) else { continue }
            let extras = iosDays[raw["id"] as? String ?? ""] as? [String: Any] ?? [:]

            let day = WorkoutDay(
                date: date(raw["startedAt"]) ?? .now,
                name: raw["name"] as? String ?? "",
                focus: TrainingFocus(rawValue: extras["focus"] as? String ?? "") ?? .bodybuilding
            )
            day.id = id
            if let dayKey = raw["date"] as? String, !dayKey.isEmpty { day.dayKey = dayKey }
            day.liveStartedAt = date(extras["liveStartedAt"])
            day.liveEndedAt = date(extras["liveEndedAt"])
            day.healthKitUUID = uuid(extras["healthKitUUID"])
            context.insert(day)

            for (index, rawExercise) in (raw["exercises"] as? [[String: Any]] ?? []).enumerated() {
                let exExtras = iosExercises[rawExercise["id"] as? String ?? ""] as? [String: Any] ?? [:]
                let exercise = ExerciseEntry(
                    exerciseRefID: exExtras["exerciseRefID"] as? String ?? "",
                    name: rawExercise["name"] as? String ?? "",
                    orderIndex: exExtras["orderIndex"] as? Int ?? index,
                    primaryMuscle: exExtras["primaryMuscle"] as? String,
                    equipment: (rawExercise["equipment"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                )
                exercise.id = uuid(rawExercise["id"]) ?? UUID()
                exercise.day = day
                context.insert(exercise)

                for (setIndex, rawSet) in (rawExercise["sets"] as? [[String: Any]] ?? []).enumerated() {
                    let setExtras = iosSets[rawSet["id"] as? String ?? ""] as? [String: Any] ?? [:]
                    let set = SetEntry(
                        orderIndex: setExtras["orderIndex"] as? Int ?? setIndex,
                        weightKg: (double(rawSet["weightLb"]) ?? 0) / lbPerKg,
                        reps: rawSet["reps"] as? Int ?? 0,
                        rpe: double(rawSet["rpe"]),
                        isWarmup: setExtras["isWarmup"] as? Bool ?? false
                    )
                    set.id = uuid(rawSet["id"]) ?? UUID()
                    set.completedAt = date(setExtras["completedAt"])
                    set.exercise = exercise
                    context.insert(set)
                }
            }
            added += 1
        }

        // Bodyweight prefers the richer ios record and falls back to the flat map.
        let existingMeasurements = Set((try? context.fetch(FetchDescriptor<BodyMeasurement>()))?.map(\.dayKey) ?? [])
        if let records = ios["measurements"] as? [[String: Any]] {
            for raw in records {
                let dayKey = raw["dayKey"] as? String ?? ""
                guard !dayKey.isEmpty, !existingMeasurements.contains(dayKey) else { continue }
                let measurement = BodyMeasurement(
                    recordedAt: date(raw["recordedAt"]) ?? .now,
                    weightKg: double(raw["weightKg"]),
                    bodyFatPercent: double(raw["bodyFatPercent"])
                )
                measurement.id = uuid(raw["id"]) ?? UUID()
                measurement.dayKey = dayKey
                measurement.healthKitUUID = uuid(raw["healthKitUUID"])
                context.insert(measurement)
                added += 1
            }
        } else if let weights = payload["weights"] as? [String: Any] {
            for (dayKey, value) in weights where !existingMeasurements.contains(dayKey) {
                guard let lb = double(value) else { continue }
                let measurement = BodyMeasurement(weightKg: lb / lbPerKg)
                measurement.dayKey = dayKey
                context.insert(measurement)
                added += 1
            }
        }

        // Single values only fill a gap, same rule as the records: restoring an
        // old file must not overwrite something already set up on this phone.
        let defaults = UserDefaults.standard
        if let coach = payload["coach"] as? [String: Any] {
            if CoachShare.Settings.email.isEmpty,
               let email = coach["email"] as? String { CoachShare.Settings.email = email }
            if CoachShare.Settings.lifterName.isEmpty,
               let you = coach["you"] as? String { CoachShare.Settings.lifterName = you }
            // Carries the lifter's identity across so their coach still sees the
            // same person — but never renumbers a phone that already has an id.
            let idKey = "coachLifterID"
            if (defaults.string(forKey: idKey) ?? "").isEmpty,
               let id = coach["id"] as? String, !id.isEmpty {
                defaults.set(id, forKey: idKey)
            }
        }

        if !defaults.bool(forKey: "goalIsSet"), let goal = payload["goal"] as? [String: Any] {
            defaults.set(double(goal["calories"]) ?? 0, forKey: "goalCalories")
            defaults.set(double(goal["proteinG"]) ?? 0, forKey: "goalProtein")
            defaults.set(double(goal["fatG"]) ?? 0, forKey: "goalFat")
            defaults.set(double(goal["carbsG"]) ?? 0, forKey: "goalCarbs")
            defaults.set(double(goal["fiberG"]) ?? 0, forKey: "goalFiber")
            defaults.set(true, forKey: "goalIsSet")
        }

        // Keep the parts of the file this app cannot read, so the next save
        // hands them back rather than dropping what an Android phone recorded.
        var foreign = ext
        foreign.removeValue(forKey: "ios")
        if foreign.isEmpty {
            UserDefaults.standard.removeObject(forKey: foreignExtKey)
        } else if let encoded = try? JSONSerialization.data(withJSONObject: foreign) {
            UserDefaults.standard.set(encoded, forKey: foreignExtKey)
        }

        try? context.save()
        return RestoreResult(added: added, ok: true, problem: nil)
    }

    static let foreignExtKey = "backupForeignExt"

    /// What a previous restore held on to from another platform.
    static func storedForeignExt() -> [String: Any] {
        guard
            let raw = UserDefaults.standard.data(forKey: foreignExtKey),
            let decoded = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        else { return [:] }
        return decoded
    }

    /// Any `ext` block belonging to another platform, so the next save can put
    /// it back rather than dropping what an Android phone recorded.
    static func foreignExt(in data: Data) -> [String: Any] {
        guard
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            var ext = root["ext"] as? [String: Any]
        else { return [:] }
        ext.removeValue(forKey: "ios")
        return ext
    }

    // MARK: - Small conversions

    private static func uuid(_ value: Any?) -> UUID? {
        (value as? String).flatMap(UUID.init(uuidString:))
    }

    private static func double(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        guard let millis = double(value) else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    static func todayKey() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
