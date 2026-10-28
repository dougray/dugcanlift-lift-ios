import Foundation
import SwiftData
import LiftCore

/// Training history in and out as CSV: in from Strong, Hevy and FitNotes, out
/// as LIFT's own one-row-per-set file.
///
/// **None of the three apps publishes its export format.** Their help pages say
/// only where the export button is. Every header, delimiter and date shape here
/// was read from real exports people have published, and the fixtures in
/// `Tests/Fixtures/csv/` are built from those shapes, not copied from a maker.
/// So the reader is strict about what it recognises and says plainly when it
/// does not: a file it cannot place is refused, never half-read.
///
/// **Weights become kilograms on the way in**, like every weight LIFT stores.
/// Hevy and FitNotes say their unit in the file. Strong's semicolon export
/// says "Weight (kg)". Strong's comma export says nothing at all, so the
/// person importing it is asked, because a guess is 2.2x wrong either way.
enum WorkoutCSV {

    // MARK: - What a file holds

    struct ImportedSet: Equatable {
        var weightKg: Double = 0
        var reps: Int = 0
        var rpe: Double?
        var isWarmup = false
        var durationSec: Int?
        var distanceMeters: Double?
    }

    struct ImportedExercise: Equatable {
        var name: String
        var equipment: String?
        var primaryMuscle: String?
        var sets: [ImportedSet]
    }

    struct ImportedWorkout: Equatable {
        var date: Date
        var name: String
        var exercises: [ImportedExercise]
    }

    enum Source: String, Equatable {
        case strong = "Strong", hevy = "Hevy", fitNotes = "FitNotes"
    }

    enum Failure: Error, Equatable {
        case notRecognised
        case empty
    }

    /// What reading a file found, before anything is written. `needsUnit` is
    /// Strong's comma export, whose numbers carry no unit: `workouts` cannot
    /// be built until the person says which.
    struct Reading {
        let source: Source
        let needsUnit: Bool
        let parse: (WeightUnit?) -> [ImportedWorkout]
    }

    static func read(_ text: String) throws -> Reading {
        let rows = parse(text)
        guard let header = rows.first, rows.count > 1 else { throw Failure.empty }
        let names = header.map { $0.trimmingCharacters(in: .whitespaces) }
        let body = Array(rows.dropFirst()).filter { !($0.count == 1 && $0[0].isEmpty) }
        let column = Columns(names)

        if column["Workout #"] != nil, column["Set Order"] != nil {
            let kg = column["Weight (kg)"] != nil
            return Reading(source: .strong, needsUnit: false) { _ in
                strong(body, column, unit: kg ? .kilograms : .pounds,
                       weightColumn: kg ? "Weight (kg)" : "Weight (lbs)", distanceInMeters: true)
            }
        }
        if column["Exercise Name"] != nil, column["Set Order"] != nil, column["Weight"] != nil {
            return Reading(source: .strong, needsUnit: true) { unit in
                strong(body, column, unit: unit ?? .kilograms, weightColumn: "Weight", distanceInMeters: true)
            }
        }
        if column["exercise_title"] != nil, column["set_type"] != nil {
            return Reading(source: .hevy, needsUnit: false) { _ in hevy(body, column) }
        }
        if column["Exercise"] != nil, column["Category"] != nil,
           column["Weight"] != nil || column["Weight (kgs)"] != nil || column["Weight (lbs)"] != nil {
            return Reading(source: .fitNotes, needsUnit: false) { _ in fitNotes(body, column) }
        }
        throw Failure.notRecognised
    }

    // MARK: - Strong

    /// One row per set, plus "Note" and "Rest Timer" rows that are not sets.
    /// `Set Order` is a number for a working set, `W` a warm-up, `D` a drop
    /// set and `F` a set to failure; the last two are working sets here.
    private static func strong(_ rows: [[String]], _ c: Columns, unit: WeightUnit,
                               weightColumn: String, distanceInMeters: Bool) -> [ImportedWorkout] {
        var builder = Builder()
        for row in rows {
            let order = c.value(row, "Set Order")
            if order == "Note" || order == "Rest Timer" { continue }
            guard let date = strongDate(c.value(row, "Date")) else { continue }
            let key = (c["Workout #"] != nil ? c.value(row, "Workout #") : "") + "|" + c.value(row, "Date")
                + "|" + c.value(row, "Workout Name")
            let (name, equipment) = splitEquipment(c.value(row, "Exercise Name"))
            var set = ImportedSet()
            set.weightKg = number(c.value(row, weightColumn)).map(unit.toKilograms) ?? 0
            set.reps = Int(number(c.value(row, "Reps")) ?? 0)
            set.rpe = number(c.value(row, "RPE")).flatMap { $0 > 0 ? $0 : nil }
            set.isWarmup = order == "W"
            set.durationSec = number(c.value(row, "Seconds")).flatMap { $0 > 0 ? Int($0.rounded()) : nil }
            let distanceColumn = c["Distance (meters)"] != nil ? "Distance (meters)" : "Distance"
            set.distanceMeters = number(c.value(row, distanceColumn)).flatMap { $0 > 0 ? $0 : nil }
            builder.add(set, workout: key, date: date, workoutName: c.value(row, "Workout Name"),
                        exercise: name, equipment: equipment, muscle: nil)
        }
        return builder.workouts
    }

    // MARK: - Hevy

    private static func hevy(_ rows: [[String]], _ c: Columns) -> [ImportedWorkout] {
        let pounds = c["weight_lbs"] != nil
        let miles = c["distance_miles"] != nil
        var builder = Builder()
        for row in rows {
            guard let date = hevyDate(c.value(row, "start_time")) else { continue }
            let key = c.value(row, "title") + "|" + c.value(row, "start_time") + "|" + c.value(row, "end_time")
            let (name, equipment) = splitEquipment(c.value(row, "exercise_title"))
            var set = ImportedSet()
            let weight = number(c.value(row, pounds ? "weight_lbs" : "weight_kg"))
            set.weightKg = weight.map { pounds ? WeightUnit.pounds.toKilograms($0) : $0 } ?? 0
            set.reps = Int(number(c.value(row, "reps")) ?? 0)
            set.rpe = number(c.value(row, "rpe"))
            set.isWarmup = c.value(row, "set_type").lowercased() == "warmup"
            set.durationSec = number(c.value(row, "duration_seconds")).flatMap { $0 > 0 ? Int($0.rounded()) : nil }
            let distance = number(c.value(row, miles ? "distance_miles" : "distance_km"))
            set.distanceMeters = distance.flatMap { $0 > 0 ? $0 * (miles ? 1609.344 : 1000) : nil }
            builder.add(set, workout: key, date: date, workoutName: c.value(row, "title"),
                        exercise: name, equipment: equipment, muscle: nil)
        }
        return builder.workouts
    }

    // MARK: - FitNotes

    /// One workout a day, which is how FitNotes keeps them. Weight's unit is
    /// on every row, and one file can mix the two.
    private static func fitNotes(_ rows: [[String]], _ c: Columns) -> [ImportedWorkout] {
        var builder = Builder()
        for row in rows {
            let day = c.value(row, "Date")
            guard let date = fitNotesDate(day) else { continue }
            var set = ImportedSet()
            let weight: Double?
            let unit: WeightUnit
            if c["Weight Unit"] != nil {
                weight = number(c.value(row, "Weight"))
                unit = c.value(row, "Weight Unit").lowercased().hasPrefix("lb") ? .pounds : .kilograms
            } else if c["Weight (lbs)"] != nil {
                weight = number(c.value(row, "Weight (lbs)")); unit = .pounds
            } else {
                weight = number(c.value(row, "Weight (kgs)")); unit = .kilograms
            }
            set.weightKg = weight.map(unit.toKilograms) ?? 0
            set.reps = Int(number(c.value(row, "Reps")) ?? 0)
            set.durationSec = clockSeconds(c.value(row, "Time"))
            if let distance = number(c.value(row, "Distance")), distance > 0 {
                let perUnit: Double = switch c.value(row, "Distance Unit").lowercased() {
                case "km": 1000
                case "mi": 1609.344
                case "ft": 0.3048
                default: 1
                }
                set.distanceMeters = distance * perUnit
            }
            // FitNotes' category is a muscle group, except "Cardio", which is not.
            let category = c.value(row, "Category").lowercased()
            builder.add(set, workout: day, date: date, workoutName: "",
                        exercise: c.value(row, "Exercise"), equipment: nil,
                        muscle: category.isEmpty || category == "cardio" ? nil : category)
        }
        return builder.workouts
    }

    // MARK: - Pieces

    /// Groups rows into workouts and exercises in the order they first appear.
    private struct Builder {
        private var order: [String] = []
        private var byKey: [String: ImportedWorkout] = [:]

        mutating func add(_ set: ImportedSet, workout key: String, date: Date, workoutName: String,
                          exercise: String, equipment: String?, muscle: String?) {
            guard !exercise.isEmpty else { return }
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = ImportedWorkout(date: date, name: workoutName, exercises: [])
            }
            var workout = byKey[key]!
            if let last = workout.exercises.indices.last,
               workout.exercises[last].name == exercise, workout.exercises[last].equipment == equipment {
                workout.exercises[last].sets.append(set)
            } else {
                workout.exercises.append(ImportedExercise(name: exercise, equipment: equipment,
                                                          primaryMuscle: muscle, sets: [set]))
            }
            byKey[key] = workout
        }

        var workouts: [ImportedWorkout] { order.compactMap { byKey[$0] }.sorted { $0.date < $1.date } }
    }

    private struct Columns {
        private let index: [String: Int]
        init(_ names: [String]) {
            var map: [String: Int] = [:]
            for (i, name) in names.enumerated() where map[name] == nil { map[name] = i }
            index = map
        }
        subscript(name: String) -> Int? { index[name] }
        func value(_ row: [String], _ name: String) -> String {
            guard let i = index[name], i < row.count else { return "" }
            return row[i].trimmingCharacters(in: .whitespaces)
        }
    }

    /// "Bench Press (Barbell)" → ("Bench Press", "Barbell"), the shape Strong
    /// and Hevy both name an exercise in. A name with no trailing bracket is
    /// left whole.
    static func splitEquipment(_ text: String) -> (String, String?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "("), open > trimmed.startIndex else {
            return (trimmed, nil)
        }
        let name = trimmed[..<open].trimmingCharacters(in: .whitespaces)
        let equipment = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty || equipment.isEmpty ? (trimmed, nil) : (name, equipment)
    }

    /// Digits and a point only: every export seen writes a point whatever the
    /// phone's language, and a comma read as a decimal would turn 1,000 m into
    /// one.
    static func number(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let value = Double(t), value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// "0:01:30" or "1:30" → seconds.
    static func clockSeconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let seconds = parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return seconds > 0 ? seconds : nil
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = format
        return f
    }

    private static let strongFormat = formatter("yyyy-MM-dd HH:mm:ss")
    private static let hevyFormats = [formatter("d MMM yyyy, HH:mm"), formatter("MMM d, yyyy, h:mm a")]
    private static let dayFormat = formatter("yyyy-MM-dd")

    /// Times have no zone in any of the three files, so they are read as the
    /// phone's own local time, which is what each app wrote them in.
    static func strongDate(_ text: String) -> Date? { strongFormat.date(from: text) }
    static func hevyDate(_ text: String) -> Date? { hevyFormats.lazy.compactMap { $0.date(from: text) }.first }
    static func fitNotesDate(_ text: String) -> Date? { dayFormat.date(from: text).map { $0.addingTimeInterval(12 * 3600) } }

    /// RFC 4180, with the delimiter taken from the header (Strong's Android
    /// export uses `;`), quotes doubled to escape, CR LF or LF, and a BOM
    /// dropped.
    static func parse(_ text: String) -> [[String]] {
        var source = Substring(text)
        if source.hasPrefix("\u{FEFF}") { source = source.dropFirst() }
        let firstLine = source.prefix { $0 != "\n" }
        let delimiter: Character = firstLine.filter { $0 == ";" }.count > firstLine.filter { $0 == "," }.count ? ";" : ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = source.startIndex
        while index < source.endIndex {
            let ch = source[index]
            if quoted {
                if ch == "\"" {
                    let next = source.index(after: index)
                    if next < source.endIndex, source[next] == "\"" { field.append("\""); index = next }
                    else { quoted = false }
                } else { field.append(ch) }
            } else if ch == "\"" {
                quoted = true
            } else if ch == delimiter {
                row.append(field); field = ""
            } else if ch == "\n" || ch == "\r\n" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else if ch != "\r" {
                field.append(ch)
            }
            index = source.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    // MARK: - LIFT's own export

    static let exportHeader = ["Date", "Workout", "Exercise", "Equipment", "Set", "Warmup", "Side",
                               "Weight (kg)", "Reps", "RPE", "Seconds", "Distance (m)"]

    struct ExportRow: Equatable {
        var dayKey: String
        var workout: String
        var exercise: String
        var equipment: String?
        var set: Int
        var isWarmup: Bool
        var side: String?
        var weightKg: Double
        var reps: Int
        var rpe: Double?
        var seconds: Int?
        var distanceMeters: Double?
    }

    /// One row per set, kilograms always, blanks blank. A point for decimals
    /// whatever the phone's language, so the file reads the same everywhere.
    static func export(_ rows: [ExportRow]) -> String {
        func cell(_ s: String) -> String {
            s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        func num(_ d: Double?) -> String {
            guard let d, d.isFinite else { return "" }
            return d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d)
                .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
        }
        var lines = [exportHeader.joined(separator: ",")]
        for r in rows {
            lines.append([r.dayKey, cell(r.workout), cell(r.exercise), cell(r.equipment ?? ""), String(r.set),
                          r.isWarmup ? "yes" : "", r.side ?? "", num(r.weightKg), String(r.reps),
                          num(r.rpe), r.seconds.map(String.init) ?? "", num(r.distanceMeters)]
                .joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Into and out of the store

extension WorkoutCSV {
    struct Outcome: Equatable {
        var daysAdded = 0
        var setsAdded = 0
        /// Days LIFT already had training on, left exactly as they were.
        var daysSkipped = 0
    }

    /// Writes imported workouts as `WorkoutDay`s. **A day LIFT already has
    /// training on is left alone**, said in the outcome, and never merged into:
    /// there is no telling an imported bench session from the same one logged
    /// by hand, and a doubled day is worse than a missing one. That also makes
    /// importing the same file twice a no-op. Two workouts on one day in the
    /// file (Hevy allows it) become one LIFT day, in the order they were done,
    /// named after the first.
    @MainActor
    static func apply(_ workouts: [ImportedWorkout], source: Source, in context: ModelContext) -> Outcome {
        var outcome = Outcome()
        let byDay = Dictionary(grouping: workouts) { DayKey.make(from: $0.date) }
        for key in byDay.keys.sorted() {
            let day = byDay[key]!.sorted { $0.date < $1.date }
            guard day.contains(where: { $0.exercises.contains { !$0.sets.isEmpty } }) else { continue }
            let existing = try? context.fetch(WorkoutQueries.day(key)).first
            if let existing, !existing.exercises.isEmpty {
                outcome.daysSkipped += 1
                continue
            }
            let target = existing ?? {
                let created = WorkoutDay(date: day[0].date)
                context.insert(created)
                return created
            }()
            if target.name.trimmingCharacters(in: .whitespaces).isEmpty {
                target.name = day.first { !$0.name.isEmpty }?.name ?? ""
            }
            for workout in day {
                for imported in workout.exercises where !imported.sets.isEmpty {
                    let entry = ExerciseEntry(exerciseRefID: "import:\(source.rawValue.lowercased())",
                                              name: imported.name, orderIndex: target.exercises.count,
                                              primaryMuscle: imported.primaryMuscle,
                                              equipment: imported.equipment)
                    entry.sets = imported.sets.enumerated().map { index, set in
                        SetEntry(orderIndex: index, weightKg: set.weightKg, reps: set.reps, rpe: set.rpe,
                                 isWarmup: set.isWarmup, durationSec: set.durationSec,
                                 distanceMeters: set.distanceMeters)
                    }
                    outcome.setsAdded += entry.sets.count
                    target.exercises.append(entry)
                }
            }
            outcome.daysAdded += 1
        }
        try? context.save()
        return outcome
    }

    /// Every logged set, oldest day first.
    @MainActor
    static func exportRows(from context: ModelContext) -> [ExportRow] {
        let days = (try? context.fetch(FetchDescriptor<WorkoutDay>(sortBy: [SortDescriptor(\.date)]))) ?? []
        return days.flatMap { day in
            day.orderedExercises.flatMap { exercise in
                exercise.orderedSets.enumerated().map { index, set in
                    ExportRow(dayKey: day.dayKey, workout: day.name, exercise: exercise.name,
                              equipment: exercise.equipment, set: index + 1, isWarmup: set.isWarmup,
                              side: set.side?.rawValue, weightKg: set.weightKg, reps: set.reps, rpe: set.rpe,
                              seconds: set.durationSec, distanceMeters: set.distanceMeters)
                }
            }
        }
    }
}
