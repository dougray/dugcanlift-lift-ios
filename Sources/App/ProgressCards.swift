import SwiftUI
import SwiftData
import Charts
import LiftCore
import LiftReference

// MARK: - Your year

/// Train → Your year: every day of the last twelve months as a square, filled
/// by how many working sets it held (`TrainingYear`). Counted, never graded:
/// an empty week is an empty column, with nothing said about it.
struct TrainingYearCard: View {
    @Query private var days: [WorkoutDay]

    init() {
        let since = Calendar.current.date(byAdding: .day, value: -380, to: .now) ?? .distantPast
        _days = Query(filter: #Predicate<WorkoutDay> { $0.date >= since })
    }

    private var setsByDay: [String: Int] {
        days.reduce(into: [:]) { counts, day in
            let working = day.exercises.reduce(0) { $0 + $1.sets.filter { !$0.isWarmup }.count }
            counts[day.dayKey, default: 0] += working
        }
    }

    var body: some View {
        let counts = setsByDay
        let weeks = TrainingYear.weeks(setsByDay: counts, today: .now)
        let total = TrainingYear.trainingDays(setsByDay: counts, today: .now)
        LiftCard(title: "Your year") {
            VStack(alignment: .leading, spacing: 10) {
                Text(total == 1 ? "1 training day in the last 12 months"
                     : "\(total) training days in the last 12 months")
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 3) {
                            ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                                VStack(spacing: 3) {
                                    ForEach(week, id: \.key) { day in square(day) }
                                }
                                .id(index)
                            }
                        }
                    }
                    // Today is at the right-hand end; start there.
                    .onAppear { proxy.scrollTo(weeks.count - 1, anchor: .trailing) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Training days over the last year")
                .accessibilityValue("\(total) days")
                HStack(spacing: 4) {
                    Text("Fewer sets")
                    ForEach(0..<4, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2).fill(fill(level)).frame(width: 10, height: 10)
                    }
                    Text("More")
                }
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            }
        }
    }

    private func square(_ day: TrainingYear.Day) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(day.isFuture ? Color.clear : fill(day.level))
            .frame(width: 11, height: 11)
    }

    private func fill(_ level: Int) -> Color {
        switch level {
        case 0: Theme.hairline
        case 1: Theme.accent.opacity(0.35)
        case 2: Theme.accent.opacity(0.65)
        default: Theme.accent
        }
    }
}

// MARK: - Muscles this week

/// Train → Muscles this week: working sets per primary muscle, Monday (or
/// the reader's first weekday) to now (`MuscleWeek`). A list with plain bars,
/// not a body drawing: a drawing needs artwork LIFT can license, and the list
/// says the same numbers.
struct MusclesThisWeekCard: View {
    @Query private var days: [WorkoutDay]
    @State private var lookup: [String: String] = [:]
    @State private var allMuscles: [String] = []

    init() {
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        _days = Query(filter: #Predicate<WorkoutDay> { $0.date >= start })
    }

    private var result: MuscleWeek.Result {
        let logged = days.flatMap(\.exercises).map {
            MuscleWeek.Logged(name: $0.name, equipment: $0.equipment, primaryMuscle: $0.primaryMuscle,
                              workingSets: $0.sets.filter { !$0.isWarmup }.count)
        }
        return MuscleWeek.tally(logged, lookup: lookup, allMuscles: allMuscles)
    }

    var body: some View {
        let result = result
        LiftCard(title: "Muscles this week") {
            VStack(alignment: .leading, spacing: 8) {
                if result.trained.isEmpty {
                    Text("No working sets yet this week.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    let most = result.trained.first?.sets ?? 1
                    ForEach(result.trained, id: \.muscle) { row in
                        HStack(spacing: 8) {
                            Text(row.muscle.capitalized)
                                .font(Theme.body)
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 120, alignment: .leading)
                            GeometryReader { geometry in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Theme.accent)
                                    .frame(width: max(4, geometry.size.width * CGFloat(row.sets) / CGFloat(most)))
                            }
                            .frame(height: 8)
                            Text("\(row.sets)")
                                .font(Theme.detail)
                                .monospacedDigit()
                                .foregroundStyle(Theme.textSecondary)
                                .frame(minWidth: 24, alignment: .trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.muscle.capitalized)
                        .accessibilityValue(row.sets == 1 ? "1 set" : "\(row.sets) sets")
                    }
                }
                if !result.untrained.isEmpty && !result.trained.isEmpty {
                    Text("No sets yet: " + result.untrained.map(\.capitalized).joined(separator: ", "))
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if result.unplacedSets > 0 {
                    Text(result.unplacedSets == 1
                         ? "1 set is from an exercise LIFT can't place on a muscle."
                         : "\(result.unplacedSets) sets are from exercises LIFT can't place on a muscle.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { await loadLookup() }
    }

    private func loadLookup() async {
        guard lookup.isEmpty,
              let records = try? await ReferenceDatabase.shared.allExercises(limit: 5000) else { return }
        var map: [String: String] = [:]
        for record in records {
            guard let muscle = record.primaryMuscle, !muscle.isEmpty else { continue }
            map[MuscleWeek.key(name: record.name, equipment: record.equipment)] = muscle
            map[MuscleWeek.key(name: record.name, equipment: nil)] = map[MuscleWeek.key(name: record.name, equipment: nil)] ?? muscle
        }
        lookup = map
        allMuscles = Array(Set(map.values.map { $0.lowercased() })).sorted()
    }
}

// MARK: - Body weight

/// Home → Body weight: weigh-ins logged here, the last ninety days as a line,
/// and a goal line when one is set (`BodyWeightTrend`). Stored as
/// `BodyMeasurement`, the same rows backups and Send to Coach already carry.
struct BodyWeightCard: View {
    @Environment(\.modelContext) private var context
    @AppStorage("weightUnit") private var unitRaw = WeightUnit.pounds.rawValue
    @AppStorage(BodyWeightTrend.goalKey) private var goalKg = 0.0
    @Query(sort: \BodyMeasurement.recordedAt) private var measurements: [BodyMeasurement]
    @State private var logging = false
    @State private var showingPhotos = false

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .pounds }

    private var points: [BodyWeightTrend.Point] {
        let since = Calendar.current.date(byAdding: .day, value: -90, to: .now) ?? .distantPast
        return BodyWeightTrend.daily(measurements.compactMap { m in
            guard let kg = m.weightKg, kg > 0, m.recordedAt >= since else { return nil }
            return .init(date: m.recordedAt, weightKg: kg)
        })
    }

    var body: some View {
        let points = points
        LiftCard(title: "Body weight") {
            VStack(alignment: .leading, spacing: 10) {
                if let line = BodyWeightTrend.summary(points, goalKg: goalKg > 0 ? goalKg : nil, unit: unit) {
                    Text(line)
                        .font(Theme.body)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No weigh-ins in the last 90 days.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                }
                if points.count > 1 { chart(points) }
                HStack(spacing: 20) {
                    Button("Log weight") { logging = true }
                    Button("Photos") { showingPhotos = true }
                }
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(Theme.accentText)
            }
        }
        .sheet(isPresented: $showingPhotos) { ProgressPhotosView() }
        .sheet(isPresented: $logging) {
            BodyWeightEntrySheet(unit: unit, goalKg: $goalKg) { kg in log(kg) }
        }
    }

    private func chart(_ points: [BodyWeightTrend.Point]) -> some View {
        Chart {
            ForEach(points, id: \.date) { point in
                LineMark(x: .value("Day", point.date), y: .value("Weight", unit.fromKilograms(point.weightKg)))
                    .foregroundStyle(Theme.accent)
                PointMark(x: .value("Day", point.date), y: .value("Weight", unit.fromKilograms(point.weightKg)))
                    .foregroundStyle(Theme.accent)
                    .symbolSize(18)
            }
            if goalKg > 0 {
                RuleMark(y: .value("Goal", unit.fromKilograms(goalKg)))
                    .foregroundStyle(Theme.textSecondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Goal").font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 150)
        .accessibilityLabel("Body weight over the last 90 days")
    }

    /// One weigh-in a day: logging again today replaces today's.
    private func log(_ kg: Double) {
        let key = DayKey.today
        if let today = measurements.last(where: { $0.dayKey == key }) {
            today.weightKg = kg
            today.recordedAt = .now
        } else {
            context.insert(BodyMeasurement(recordedAt: .now, weightKg: kg))
        }
        try? context.save()
    }
}

private struct BodyWeightEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    let unit: WeightUnit
    @Binding var goalKg: Double
    let onSave: (Double) -> Void

    @State private var weightText = ""
    @State private var goalText = ""

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumFractionDigits = 1
        return f
    }()

    private func value(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let number = Self.formatter.number(from: trimmed)?.doubleValue,
              number.isFinite, number > 0 else { return nil }
        return number
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Weight (\(unit.abbreviation))", text: $weightText)
                        .keyboardType(.decimalPad)
                } footer: {
                    Text("One weigh-in a day: logging again today replaces today's.")
                }
                Section {
                    TextField("Goal (\(unit.abbreviation)), optional", text: $goalText)
                        .keyboardType(.decimalPad)
                } footer: {
                    Text("Drawn as a line on the chart. Leave it blank for none.")
                }
            }
            .navigationTitle("Log weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let weight = value(weightText) { onSave(unit.toKilograms(weight)) }
                        goalKg = value(goalText).map(unit.toKilograms) ?? 0
                        dismiss()
                    }
                }
            }
            .onAppear {
                if goalKg > 0 {
                    goalText = Self.formatter.string(from: NSNumber(value: (unit.fromKilograms(goalKg) * 10).rounded() / 10)) ?? ""
                }
            }
        }
    }
}
