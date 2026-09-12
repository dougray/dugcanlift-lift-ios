import SwiftUI
import SwiftData
import WidgetKit
import LiftCore
import LiftReference

/// Day-based training log. Previous / Next walks calendar days; a day record
/// is created lazily on first edit so browsing empty dates costs nothing.
struct TrainView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("weightUnit") private var unitRaw = WeightUnit.pounds.rawValue

    @State private var selectedDate = Date.now
    @State private var showingPicker = false

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .pounds }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    dayNavigator

                    Text("Focus")
                        .font(Theme.sectionLabel)
                        .foregroundStyle(Theme.textPrimary)

                    FocusPicker(date: selectedDate)

                    ScheduledSessionBanner(date: selectedDate)

                    DayEditor(date: selectedDate, unit: unit, showingPicker: $showingPicker)

                    OutdoorDaySection(date: selectedDate)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .liftScreen()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingPicker) {
                ExercisePickerView { record in
                    addExercise(record)
                }
            }
        }
    }

    // MARK: Day navigation

    private var dayNavigator: some View {
        HStack {
            Button("Previous") { shift(-1) }
                .foregroundStyle(Theme.accent)
            Spacer()
            Text(relativeLabel)
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button("Next") { shift(1) }
                .foregroundStyle(isToday ? Theme.textSecondary : Theme.accent)
                .disabled(isToday)
        }
        .font(.system(size: 16, weight: .semibold))
        .padding(.top, 8)
    }

    private var isToday: Bool {
        DayKey.make(from: selectedDate) == DayKey.today
    }

    private var relativeLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(selectedDate) { return "Today" }
        if calendar.isDateInYesterday(selectedDate) { return "Yesterday" }
        return selectedDate.formatted(.dateTime.weekday(.abbreviated).month().day())
    }

    private func shift(_ days: Int) {
        guard let moved = Calendar.current.date(byAdding: .day, value: days, to: selectedDate)
        else { return }
        selectedDate = moved
    }

    private func addExercise(_ record: ExerciseRecord) {
        let day = WorkoutQueries.fetchOrCreate(selectedDate, in: context)
        let entry = ExerciseEntry(
            exerciseRefID: record.id,
            name: record.name,
            orderIndex: day.exercises.count,
            primaryMuscle: record.primaryMuscle,
            equipment: record.equipment
        )
        entry.sets = [SetEntry(orderIndex: 0)]
        day.exercises.append(entry)
        try? context.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Bodybuilding / powerlifting / crossfit / conditioning, for one day.
///
/// Backed by `@Query` rather than an ad-hoc `context.fetch` in a computed
/// property, so the highlighted chip actually updates when tapped — SwiftData
/// only re-renders views that hold a live query on the changed object.
private struct FocusPicker: View {
    @Environment(\.modelContext) private var context
    let date: Date

    @Query private var days: [WorkoutDay]

    init(date: Date) {
        self.date = date
        let key = DayKey.make(from: date)
        _days = Query(filter: #Predicate<WorkoutDay> { $0.dayKey == key })
    }

    private var currentFocus: TrainingFocus { days.first?.focus ?? .bodybuilding }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(TrainingFocus.allCases) { focus in
                    LiftChip(label: focus.displayName, isSelected: currentFocus == focus) {
                        setFocus(focus)
                    }
                }
            }
        }
    }

    private func setFocus(_ focus: TrainingFocus) {
        let day = days.first ?? WorkoutQueries.fetchOrCreate(date, in: context)
        day.focus = focus
        try? context.save()
    }
}

/// "Coach scheduled: Lower A" for the selected day, if a coach's plan
/// scheduled anything here. Tapping it starts the routine the same manual
/// way starting any routine already works — this never pre-creates a
/// WorkoutDay on its own.
private struct ScheduledSessionBanner: View {
    let date: Date
    @Environment(\.modelContext) private var context

    @Query private var sessions: [ScheduledSession]

    init(date: Date) {
        self.date = date
        let key = DayKey.make(from: date)
        _sessions = Query(filter: #Predicate<ScheduledSession> { $0.dayKey == key })
    }

    var body: some View {
        ForEach(sessions) { session in
            Button {
                start(session)
            } label: {
                Label("Coach scheduled: \(session.routineName)", systemImage: "person.crop.circle.badge.clock")
            }
        }
    }

    private func start(_ session: ScheduledSession) {
        // Bind to a local constant before the #Predicate closure rather than
        // reading the property inside it — matches the pattern
        // PlanImporter.accept already uses elsewhere in this codebase.
        let targetRoutineID = session.routineID
        let descriptor = FetchDescriptor<Routine>(
            predicate: #Predicate<Routine> { $0.id == targetRoutineID }
        )
        guard let routine = try? context.fetch(descriptor).first else { return }
        routine.startSession(on: date, in: context)
    }
}

/// The card containing name, summary and every exercise for one day.
private struct DayEditor: View {
    @Environment(\.modelContext) private var context
    let date: Date
    let unit: WeightUnit
    @Binding var showingPicker: Bool

    @Query private var days: [WorkoutDay]

    init(date: Date, unit: WeightUnit, showingPicker: Binding<Bool>) {
        self.date = date
        self.unit = unit
        self._showingPicker = showingPicker
        let key = DayKey.make(from: date)
        _days = Query(filter: #Predicate<WorkoutDay> { $0.dayKey == key })
    }

    private var day: WorkoutDay? { days.first }

    var body: some View {
        LiftCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Workout name")
                    .font(Theme.detail)
                    .foregroundStyle(Theme.textSecondary)

                TextField("Push, Pull, Legs…", text: nameBinding)
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textPrimary)
                    .textFieldStyle(.plain)

                if let day, day.totalSetCount > 0 {
                    Text(day.summary(unit: unit))
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                }

                if let day {
                    ForEach(day.orderedExercises) { exercise in
                        ExerciseBlock(exercise: exercise, unit: unit)
                        Divider().overlay(Theme.hairline)
                    }
                }

                Button {
                    showingPicker = true
                } label: {
                    Label("Add exercise", systemImage: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }

                liveSessionControl
            }
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { day?.name ?? "" },
            set: { newValue in
                let target = day ?? WorkoutQueries.fetchOrCreate(date, in: context)
                target.name = newValue
                try? context.save()
            }
        )
    }

    /// Optional overlay — a day log is complete without ever starting this.
    @ViewBuilder
    private var liveSessionControl: some View {
        if let day, day.isLive {
            HStack {
                Label("Live session", systemImage: "record.circle")
                    .foregroundStyle(Theme.accent)
                Spacer()
                Button("End") {
                    day.liveEndedAt = .now
                    try? context.save()
                    Task { await HealthKitManager.shared.syncPending(context: context) }
                }
                .foregroundStyle(Theme.accent)
            }
            .font(.system(size: 15, weight: .semibold))
        } else if Calendar.current.isDateInToday(date), day?.liveEndedAt == nil {
            Button {
                let target = day ?? WorkoutQueries.fetchOrCreate(date, in: context)
                target.liveStartedAt = .now
                try? context.save()
            } label: {
                Label("Start live session", systemImage: "play.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

private struct ExerciseBlock: View {
    @Environment(\.modelContext) private var context
    @Bindable var exercise: ExerciseEntry
    let unit: WeightUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(exercise.displayName)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Remove") { remove() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }

            ForEach(Array(exercise.orderedSets.enumerated()), id: \.element.id) { index, set in
                SetRow(index: index + 1, set: set, unit: unit) {
                    delete(set)
                }
            }

            Button("Add set") { addSet() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func addSet() {
        let previous = exercise.orderedSets.last
        exercise.sets.append(SetEntry(
            orderIndex: exercise.sets.count,
            weightKg: previous?.weightKg ?? 0,
            reps: previous?.reps ?? 0,
            rpe: previous?.rpe
        ))
        save()
    }

    private func delete(_ set: SetEntry) {
        exercise.sets.removeAll { $0.id == set.id }
        context.delete(set)
        save()
    }

    private func remove() {
        exercise.day?.exercises.removeAll { $0.id == exercise.id }
        context.delete(exercise)
        save()
    }

    private func save() {
        try? context.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// "1.  325 x 5 @7.5" with an inline editor on tap.
private struct SetRow: View {
    let index: Int
    @Bindable var set: SetEntry
    let unit: WeightUnit
    let onDelete: () -> Void

    @Environment(\.modelContext) private var context
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("\(index).")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, alignment: .leading)

                Button {
                    isEditing.toggle()
                } label: {
                    Text(set.display(unit: unit))
                        .font(.system(size: 16, weight: set.isWarmup ? .regular : .semibold))
                        .foregroundStyle(set.isWarmup ? Theme.textSecondary : Theme.textPrimary)
                }
                .buttonStyle(.plain)

                if set.isWarmup {
                    Text("warmup")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Button {
                    onDelete()
                } label: {
                    Text("x")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }

            if isEditing {
                editor
            }
        }
    }

    private var editor: some View {
        HStack(spacing: 8) {
            field(unit.abbreviation, value: weightBinding, width: 78, decimal: true)
            Text("x").foregroundStyle(Theme.textSecondary)
            field("reps", value: Binding(
                get: { Double(set.reps) },
                set: { set.reps = Int($0); save() }
            ), width: 62, decimal: false)
            Text("@").foregroundStyle(Theme.textSecondary)
            field("RPE", value: Binding(
                get: { set.rpe ?? 0 },
                set: { set.rpe = $0 == 0 ? nil : $0; save() }
            ), width: 62, decimal: true)

            Spacer()

            Button(set.isWarmup ? "Working" : "Warmup") {
                set.isWarmup.toggle()
                save()
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.leading, 32)
    }

    private var weightBinding: Binding<Double> {
        Binding(
            get: { unit.fromKilograms(set.weightKg) },
            set: { set.weightKg = unit.toKilograms($0); save() }
        )
    }

    private func field(_ prompt: String, value: Binding<Double>,
                       width: CGFloat, decimal: Bool) -> some View {
        TextField(prompt, value: value, format: .number)
            .keyboardType(decimal ? .decimalPad : .numberPad)
            .multilineTextAlignment(.center)
            .font(.system(size: 15))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: width)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1)
            }
    }

    private func save() {
        try? context.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Run/Hike for the selected day, alongside "See all" for full history.
/// Kept a peer to the strength `DayEditor` rather than a `TrainingFocus`
/// chip since a day can have both a lift and a run.
private struct OutdoorDaySection: View {
    let date: Date
    @AppStorage("distanceUnit") private var unitRaw = DistanceUnit.miles.rawValue
    @State private var startingActivityType: OutdoorActivityType?
    @State private var justFinishedActivity: OutdoorActivity?

    @Query private var activities: [OutdoorActivity]

    private var unit: DistanceUnit { DistanceUnit(rawValue: unitRaw) ?? .miles }

    init(date: Date) {
        self.date = date
        let start = Calendar.current.startOfDay(for: date)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        _activities = Query(
            filter: #Predicate<OutdoorActivity> { $0.startedAt >= start && $0.startedAt < end },
            sort: \OutdoorActivity.startedAt
        )
    }

    var body: some View {
        LiftCard(title: "Outdoor") {
            HStack {
                Button("Start Run") { startingActivityType = .run }
                Button("Start Hike") { startingActivityType = .hike }
                Spacer()
                NavigationLink("See all") {
                    OutdoorActivityListView()
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.accent)

            ForEach(activities) { activity in
                NavigationLink {
                    OutdoorActivityReviewView(activity: activity)
                } label: {
                    HStack {
                        Text(activity.activityType.displayName)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(String(format: "%.2f %@", unit.fromMeters(activity.distanceMeters), unit.abbreviation))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .font(.system(size: 15))
                }
            }
        }
        .fullScreenCover(item: $startingActivityType) { type in
            NavigationStack {
                OutdoorActivityRecordingView(activityType: type) { activity in
                    startingActivityType = nil
                    justFinishedActivity = activity
                }
            }
        }
        .fullScreenCover(item: $justFinishedActivity) { activity in
            NavigationStack {
                OutdoorActivityReviewView(activity: activity)
            }
        }
    }
}
