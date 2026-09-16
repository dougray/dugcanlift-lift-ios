import Foundation
import SwiftData
import LiftCore

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
            facts.sugarG.map { extras["sugarG"] = $0 }
            facts.sodiumMg.map { extras["sodiumMg"] = $0 }
            entry.healthKitUUID.map { extras["healthKitUUID"] = $0.uuidString }
            iosFood[key] = extras

            // amountGrams lives in the common shape, not ext.ios: LIFT
            // Android also has this field and writes it at the top level
            // of its own food[] objects (its JSON encoder has no
            // common/extras split at all), so nesting it under an
            // iOS-only extras block here would make a backup taken on
            // either platform silently lose the field when restored on
            // the other. See coach/BACKUP-FORMAT.md in dugcanlift-site.
            var common: [String: Any] = [
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
            entry.amountGrams.map { common["amountGrams"] = $0 }
            return common
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

        // ---- recipes and the meal plan ----
        // The common shape is what LIFT web and Android already store, so the
        // work here is spelling: recipeID -> recipeId, dayKey -> date,
        // sourceURL -> sourceUrl, isOptional -> optional, lower-case meal types
        // -> upper. What the common shape has no field for goes under ext.ios.
        var iosRecipes: [String: Any] = [:]
        var recipeRecords: [[String: Any]] = []
        for recipe in try context.fetch(FetchDescriptor<Recipe>()) {
            let key = recipe.id.uuidString
            var record: [String: Any] = [
                "id": key,
                "name": recipe.name,
                "servings": recipe.servings,
                "steps": recipe.steps,
                "importedAt": Int((recipe.createdAt.timeIntervalSince1970 * 1000).rounded())
            ]
            recipe.totalWeightGrams.map { record["totalWeightGrams"] = $0 }
            recipe.sourceURL.map { record["sourceUrl"] = $0.absoluteString }
            recipe.sourceAuthor.map { record["sourceAuthor"] = $0 }
            recipe.sourceTranscript.map { record["sourceTranscript"] = $0 }
            recipe.prepMinutes.map { record["prepMinutes"] = $0 }
            recipe.cookMinutes.map { record["cookMinutes"] = $0 }

            var extras: [String: Any] = [:]
            if let facts = recipe.nutritionPerServing {
                var nutrition = nutritionRecord(facts)
                // Recipe-level on iOS, nutrition-level everywhere else.
                nutrition["estimated"] = recipe.nutritionIsEstimated
                record["nutritionPerServing"] = nutrition
                facts.sugarG.map { extras["sugarG"] = $0 }
                facts.sodiumMg.map { extras["sodiumMg"] = $0 }
            }

            var foodRefs: [String: Any] = [:]
            let ingredients = (recipe.ingredients ?? []).sorted { $0.sortOrder < $1.sortOrder }
            record["ingredients"] = ingredients.enumerated().map { index, ingredient -> [String: Any] in
                var line: [String: Any] = ["rawText": ingredient.rawText, "optional": ingredient.isOptional]
                ingredient.item.map { line["item"] = $0 }
                ingredient.qty.map { line["qty"] = $0 }
                ingredient.unit.map { line["unit"] = $0 }
                ingredient.grams.map { line["grams"] = $0 }
                ingredient.note.map { line["note"] = $0 }
                ingredient.foodRefID.map { foodRefs[String(index)] = $0 }
                return line
            }
            if !foodRefs.isEmpty { extras["ingredientFoodRefIDs"] = foodRefs }
            if !extras.isEmpty { iosRecipes[key] = extras }
            recipeRecords.append(record)
        }
        data["recipes"] = recipeRecords

        var iosPlan: [String: Any] = [:]
        data["plan"] = try context.fetch(FetchDescriptor<PlannedMeal>()).map { meal -> [String: Any] in
            let key = meal.id.uuidString
            var record: [String: Any] = [
                "id": key,
                "recipeId": meal.recipeID.uuidString,
                "recipeName": meal.recipeName,
                "date": meal.dayKey,
                "meal": meal.mealType.rawValue.uppercased(),
                "servings": meal.servings,
                "loggedFoodEntryId": meal.loggedFoodEntryID.map { $0.uuidString as Any } ?? NSNull()
            ]
            meal.amountGrams.map { record["amountGrams"] = $0 }
            meal.snapshotNutrition.map { record["snapshotNutrition"] = nutritionRecord($0) }
            meal.snapshotNutritionPerGram.map { record["snapshotNutritionPerGram"] = nutritionRecord($0) }
            iosPlan[key] = ["plannedFor": Int((meal.plannedFor.timeIntervalSince1970 * 1000).rounded())]
            return record
        }

        // A section another client wrote that this app does not store goes back
        // out as it came in. Added last-wins-never: it can only fill a key this
        // app did not write, so a preserved copy cannot roll back real data.
        for (section, value) in storedForeignData() where data[section] == nil && !neverBackedUp.contains(section) {
            data[section] = value
        }

        var ios: [String: Any] = [:]
        if !iosRecipes.isEmpty { ios["recipes"] = iosRecipes }
        if !iosPlan.isEmpty { ios["plan"] = iosPlan }
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
            guard let id = recordID(raw["id"]), !existingFood.contains(id) else { continue }
            let extras = iosFood[raw["id"] as? String ?? ""] as? [String: Any] ?? [:]

            let entry = FoodEntry(
                foodRefID: extras["foodRefID"] as? String ?? "",
                name: raw["name"] as? String ?? "",
                brand: extras["brand"] as? String,
                quantity: double(raw["servings"]) ?? 1,
                servingUnit: extras["servingUnit"] as? String ?? "serving",
                servingGrams: double(extras["servingGrams"]),
                amountGrams: double(raw["amountGrams"]),
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
            guard let id = recordID(raw["id"]), !existingDays.contains(id) else { continue }
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

        // Recipes, then the plan, so a meal whose recipe arrives in this same
        // file can find it.
        let iosRecipes = ios["recipes"] as? [String: Any] ?? [:]
        let iosPlan = ios["plan"] as? [String: Any] ?? [:]
        var recipesByID = Dictionary(
            ((try? context.fetch(FetchDescriptor<Recipe>())) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })

        for raw in payload["recipes"] as? [[String: Any]] ?? [] {
            guard let id = recordID(raw["id"]), recipesByID[id] == nil else { continue }
            let extras = iosRecipes[raw["id"] as? String ?? ""] as? [String: Any] ?? [:]
            let nutrition = raw["nutritionPerServing"] as? [String: Any]

            let recipe = Recipe(
                name: raw["name"] as? String ?? "",
                servings: double(raw["servings"]) ?? 1,
                steps: raw["steps"] as? [String] ?? [],
                sourceURL: (raw["sourceUrl"] as? String).flatMap(URL.init(string:)),
                sourceAuthor: raw["sourceAuthor"] as? String,
                nutritionPerServing: facts(nutrition, sugar: extras["sugarG"], sodium: extras["sodiumMg"]),
                nutritionIsEstimated: nutrition?["estimated"] as? Bool ?? false,
                sourceTranscript: raw["sourceTranscript"] as? String,
                createdAt: date(raw["importedAt"]) ?? .now
            )
            recipe.id = id
            recipe.totalWeightGrams = double(raw["totalWeightGrams"]).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            recipe.prepMinutes = raw["prepMinutes"] as? Int
            recipe.cookMinutes = raw["cookMinutes"] as? Int
            context.insert(recipe)

            // Reparsed from rawText, which is the contract: every client runs the
            // same parser. Only the fields the parser does not own come from the
            // file, so a cached quantity cannot outlive a line that no longer
            // parses to it.
            let foodRefs = extras["ingredientFoodRefIDs"] as? [String: Any] ?? [:]
            for (index, rawLine) in (raw["ingredients"] as? [Any] ?? []).enumerated() {
                let line = rawLine as? [String: Any]
                let text = (rawLine as? String) ?? (line?["rawText"] as? String) ?? ""
                let ingredient = IngredientParser.parse(text, sortOrder: index)
                ingredient.isOptional = line?["optional"] as? Bool ?? false
                ingredient.note = line?["note"] as? String
                ingredient.foodRefID = foodRefs[String(index)] as? String
                ingredient.recipe = recipe
                context.insert(ingredient)
            }
            recipesByID[id] = recipe
            added += 1
        }

        let existingMeals = Set((try? context.fetch(FetchDescriptor<PlannedMeal>()))?.map(\.id) ?? [])
        for raw in payload["plan"] as? [[String: Any]] ?? [] {
            guard let id = recordID(raw["id"]), !existingMeals.contains(id) else { continue }
            // A meal whose recipe is in neither the file nor this phone would be
            // a meal with nothing behind it.
            guard let recipeID = recordID(raw["recipeId"]), let recipe = recipesByID[recipeID] else { continue }
            let extras = iosPlan[raw["id"] as? String ?? ""] as? [String: Any] ?? [:]
            let dayKey = raw["date"] as? String ?? ""

            let meal = PlannedMeal(
                recipe: recipe,
                mealType: MealType(rawValue: (raw["meal"] as? String ?? "dinner").lowercased()) ?? .dinner,
                plannedFor: date(extras["plannedFor"]) ?? DayKey.date(from: dayKey) ?? .now,
                servings: double(raw["servings"]) ?? 1,
                amountGrams: double(raw["amountGrams"]).flatMap { $0 > 0 ? $0 : nil }
            )
            meal.id = id
            if !dayKey.isEmpty { meal.dayKey = dayKey }
            // The file's snapshot is history: what the recipe said when the meal
            // was planned. The init copied today's recipe, which may since have
            // been edited, so the file wins -- including when it has no snapshot.
            meal.recipeName = raw["recipeName"] as? String ?? recipe.name
            meal.snapshotNutrition = facts(raw["snapshotNutrition"] as? [String: Any])
            meal.snapshotNutritionPerGram = facts(raw["snapshotNutritionPerGram"] as? [String: Any])
            meal.loggedFoodEntryID = recordID(raw["loggedFoodEntryId"])
            context.insert(meal)
            added += 1
        }

        // A data section this app does not store -- web's `steps` and `profile`,
        // Android's `routines`, anything a newer client adds -- is kept and
        // written back out, exactly like ext. Without it, restoring an Android
        // backup here and saving again silently dropped every routine.
        var foreignData = storedForeignData()
        for (section, value) in payload where !storedSections.contains(section) && !neverBackedUp.contains(section) {
            foreignData[section] = value
        }
        if foreignData.isEmpty {
            UserDefaults.standard.removeObject(forKey: foreignDataKey)
        } else if let encoded = try? JSONSerialization.data(withJSONObject: foreignData) {
            UserDefaults.standard.set(encoded, forKey: foreignDataKey)
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
    static let foreignDataKey = "backupForeignData"

    /// Sections this app writes from its own data. Anything else a file's `data`
    /// carries is preserved rather than dropped. See BACKUP-FORMAT.md, "Unknown
    /// sections".
    static let storedSections: Set<String> = [
        "food", "workouts", "weights", "coach", "goal", "settings", "recipes", "plan"
    ]

    /// Never written and never preserved, by the format: ticks mark one week's
    /// shop, and restoring last month's would show this week's list as bought.
    static let neverBackedUp: Set<String> = ["shopping"]

    /// Sections a previous restore held on to because this app does not store them.
    static func storedForeignData() -> [String: Any] {
        guard
            let raw = UserDefaults.standard.data(forKey: foreignDataKey),
            let decoded = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        else { return [:] }
        return decoded
    }

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

    /// A record's id as this app stores it: the UUID when it is one, and a stable
    /// UUID derived from the string when it is not.
    ///
    /// The browser falls back to a non-UUID id where `crypto.randomUUID` is
    /// unavailable, and this used to skip any such record outright -- a food
    /// entry lost, or, for a recipe, every planned meal pointing at it orphaned.
    /// Stable, so restoring the same file twice recognises what it already has,
    /// and so a planned meal's `recipeId` derives to the same UUID as its recipe.
    /// Case is irrelevant here: two spellings of one UUID parse to one value.
    static func recordID(_ value: Any?) -> UUID? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        if let real = UUID(uuidString: text) { return real }
        // FNV-1a over the bytes, spread across 128 bits. Not cryptographic; it
        // only needs to be deterministic and to separate distinct strings.
        var high: UInt64 = 0xcbf29ce484222325
        var low: UInt64 = 0x84222325cbf29ce4
        for byte in text.utf8 {
            high = (high ^ UInt64(byte)) &* 0x100000001b3
            low = (low &* 0x100000001b3) ^ UInt64(byte)
        }
        var bytes = withUnsafeBytes(of: high.bigEndian, Array.init)
        bytes += withUnsafeBytes(of: low.bigEndian, Array.init)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Macros in the file's shape. Sugar and sodium have no place in the common
    /// shape, so a recipe's travel under ext.ios.
    private static func nutritionRecord(_ facts: NutritionFacts) -> [String: Any] {
        var out: [String: Any] = [
            "calories": facts.calories,
            "proteinG": facts.proteinG,
            "carbsG": facts.carbsG,
            "fatG": facts.fatG
        ]
        facts.fiberG.map { out["fiberG"] = $0 }
        return out
    }

    /// Macros from the file. nil when the file has none -- never zeros, which
    /// would log as a zero-calorie meal.
    private static func facts(_ raw: [String: Any]?, sugar: Any? = nil, sodium: Any? = nil) -> NutritionFacts? {
        guard let raw else { return nil }
        return NutritionFacts(
            calories: double(raw["calories"]) ?? 0,
            proteinG: double(raw["proteinG"]) ?? 0,
            carbsG: double(raw["carbsG"]) ?? 0,
            fatG: double(raw["fatG"]) ?? 0,
            fiberG: double(raw["fiberG"]),
            sugarG: double(sugar),
            sodiumMg: double(sodium)
        )
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
