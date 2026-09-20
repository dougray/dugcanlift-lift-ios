import MapKit
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

    @AppStorage(PerSideLogging.storageKey) private var perSideRaw = "{}"

    @State private var selectedDate = Date.now
    @State private var showingPicker = false
    @Environment(\.pageWidth) private var pageWidth

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .pounds }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    dayNavigator

                    // The day's lifting on the left and its runs, walks and
                    // hikes on the right, once each half is wide enough for a
                    // set's inline editor (weight x reps @ RPE, Warmup).
                    AdaptiveColumns(columns: AdaptiveLayout.columns(
                        for: AdaptiveLayout.contentWidth(forPage: pageWidth), minWidth: 394)) {
                        VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                            Text("Focus")
                                .font(Theme.sectionLabel)
                                .foregroundStyle(Theme.textPrimary)

                            FocusPicker(date: selectedDate)

                            ScheduledSessionBanner(date: selectedDate)

                            DayEditor(date: selectedDate, unit: unit, showingPicker: $showingPicker)
                        }

                        VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                            OutdoorDaySection(date: selectedDate)

                            OutdoorHighlights()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
                .adaptivePageWidth()
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
        // The preference is answered before the exercise exists, so the set
        // that comes with it can already carry a side. Without this, the very
        // first set of every single-arm lift would be a two-sided one the
        // lifter has to go back and fix.
        let perSide = PerSideLogging.effective(
            name: record.name, equipment: record.equipment, in: perSideRaw)
        entry.sets = [SetEntry(orderIndex: 0, side: perSide ? .left : nil)]
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
                        ExerciseBlock(exercise: exercise, unit: unit,
                                      focus: day.focus)
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
    @AppStorage(PerSideLogging.storageKey) private var perSideRaw = "{}"
    @Bindable var exercise: ExerciseEntry
    let unit: WeightUnit
    let focus: TrainingFocus

    /// Whether this lift is being logged a limb at a time: the lifter's own
    /// answer if they have given one, otherwise what the name suggests. The
    /// toggle is offered on every exercise, because the exercise database has
    /// no unilateral column and a name is only ever a guess.
    private var perSide: Bool {
        PerSideLogging.effective(name: exercise.name,
                                 equipment: exercise.equipment, in: perSideRaw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    // The name opens the lift's own progression — two lines
                    // and the gap between them when it is logged per side.
                    NavigationLink {
                        ExerciseProgressionView(name: exercise.name,
                                                equipment: exercise.equipment)
                    } label: {
                        Text(exercise.displayName)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)

                    // "L 3 · R 3". A missed side is the failure this whole
                    // feature exists to make visible, so the count sits in
                    // the header rather than waiting to be counted by eye.
                    if perSide {
                        Text(exercise.perSideCountLabel)
                            .font(Theme.detail)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                Button("Remove") { remove() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }

            Button {
                perSideRaw = PerSideLogging.setting(
                    !perSide,
                    for: ExerciseKey.make(name: exercise.name, equipment: exercise.equipment),
                    in: perSideRaw)
            } label: {
                Label("Log left and right separately",
                      systemImage: perSide ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(perSide ? Theme.accent : Theme.textSecondary)
            }
            .buttonStyle(.plain)

            ForEach(Array(exercise.orderedSets.enumerated()), id: \.element.id) { index, set in
                SetRow(index: index + 1, set: set, unit: unit, focus: focus,
                       showsSide: perSide) {
                    delete(set)
                }
            }

            Button("Add set") { addSet() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func addSet() {
        // The set before is the best guess there is; the focus only has to
        // answer for the first one, where 5 and 10 are different training
        // decisions. Time and distance are never carried forward — a second
        // interval is rarely the same length as the first, and a wrong number
        // that looks deliberate is worse than an empty field.
        //
        // When sides are being logged, the set before is the *other* limb's,
        // because `nextSide` alternates — which is exactly the "same as last"
        // shortcut the spec asks for: most people match reps across limbs and
        // adjust the weight, so copying and editing beats typing from
        // nothing. One tap more than a normal set, not two.
        let previous = exercise.orderedSets.last
        exercise.sets.append(SetEntry(
            orderIndex: exercise.sets.count,
            weightKg: previous?.weightKg ?? 0,
            reps: previous?.reps ?? focus.defaultReps ?? 0,
            rpe: previous?.rpe,
            side: perSide ? exercise.nextSide : nil
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
    let focus: TrainingFocus
    /// Whether this lift is logged a limb at a time. Off, this row is exactly
    /// what it has always been — no control, no side in the text.
    var showsSide: Bool = false
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

                // In the row, not behind a tap on the editor: picking the
                // limb has to cost one tap, and a set already lands on the
                // side with fewer logged, so most of the time it costs none.
                if showsSide { sidePicker }

                Button {
                    isEditing.toggle()
                } label: {
                    // The control beside it already says L or R.
                    Text(set.display(unit: unit, includingSide: !showsSide))
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

    /// Two buttons rather than a `Picker`: a segmented picker cannot express
    /// "neither", and a set logged before this exercise was switched to
    /// per-side has no side at all. Tapping the highlighted side clears it
    /// back to both, so nothing is a one-way door.
    private var sidePicker: some View {
        HStack(spacing: 0) {
            ForEach(SetSide.allCases) { side in
                Button {
                    set.side = set.side == side ? nil : side
                    save()
                } label: {
                    Text(side.shortLabel)
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(set.side == side ? Theme.background : Theme.textSecondary)
                        .background {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(set.side == side ? Theme.accent : Color.clear)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(side.displayName)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 1)
        }
    }

    /// Only the fields the focus asks for. Nothing already stored is dropped:
    /// a set logged under Hyrox keeps its distance when the day is switched to
    /// Bodybuilding, the editor just stops offering it, and `display` still
    /// shows it.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if focus.showsWeight {
                    field(unit.abbreviation, value: weightBinding, width: 78, decimal: true)
                }
                if focus.showsWeight && focus.showsReps {
                    Text("x").foregroundStyle(Theme.textSecondary)
                }
                if focus.showsReps {
                    field("reps", value: Binding(
                        get: { Double(set.reps) },
                        set: { set.reps = Int($0); save() }
                    ), width: 62, decimal: false)
                }
                if focus.showsRPE {
                    Text("@").foregroundStyle(Theme.textSecondary)
                    field("RPE", value: Binding(
                        get: { set.rpe ?? 0 },
                        set: { set.rpe = $0 == 0 ? nil : $0; save() }
                    ), width: 62, decimal: true)
                }

                Spacer()

                Button(set.isWarmup ? "Working" : "Warmup") {
                    set.isWarmup.toggle()
                    save()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            }

            if focus.showsTime || focus.showsDistance {
                HStack(spacing: 8) {
                    if focus.showsTime {
                        TextField("mm:ss", text: durationBinding)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 78)
                            .padding(.vertical, 7)
                            .background {
                                RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1)
                            }
                    }
                    if focus.showsDistance {
                        field("metres", value: Binding(
                            get: { set.distanceMeters ?? 0 },
                            set: { set.distanceMeters = $0 == 0 ? nil : $0; save() }
                        ), width: 86, decimal: true)
                    }
                    Spacer()
                }
            }
        }
        .padding(.leading, 32)
    }

    /// Text rather than a number, because "1:30" is how a ninety-second
    /// interval is written. An unparseable string clears the field instead of
    /// storing a zero — a set that was never timed is not a zero-second set.
    private var durationBinding: Binding<String> {
        Binding(
            get: { set.durationSec.map { SetMetrics.clock($0) } ?? "" },
            set: { set.durationSec = SetMetrics.parseDuration($0); save() }
        )
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
            HStack(spacing: 16) {
                Button { startingActivityType = .run } label: {
                    Label("Run", systemImage: "figure.run")
                }
                Button { startingActivityType = .walk } label: {
                    Label("Walk", systemImage: "figure.walk")
                }
                Button { startingActivityType = .hike } label: {
                    Label("Hike", systemImage: "figure.hiking")
                }
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

/// The space under Outdoor: the newest route on a map, and the best distance,
/// time and pace for each kind of activity. All-time rather than the selected
/// day's, so it is still there on a rest day.
private struct OutdoorHighlights: View {
    @AppStorage("distanceUnit") private var unitRaw = DistanceUnit.miles.rawValue
    @Query(sort: \OutdoorActivity.startedAt, order: .reverse) private var activities: [OutdoorActivity]

    private var unit: DistanceUnit { DistanceUnit(rawValue: unitRaw) ?? .miles }

    var body: some View {
        let last = OutdoorRecords.lastRoute(in: activities)
        let bests = OutdoorRecords.bests(in: activities)

        if let last {
            LiftCard(title: "Last route") {
                NavigationLink {
                    OutdoorActivityReviewView(activity: last)
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        RouteMap(points: last.routePoints)
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                        HStack {
                            Text(last.activityType.displayName)
                                .foregroundStyle(Theme.textPrimary)
                            Text(last.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                        }
                        .font(.system(size: 15, weight: .semibold))

                        HStack(spacing: 0) {
                            stat("Distance", OutdoorRecords.distanceText(last.distanceMeters, unit: unit))
                            stat("Time", last.duration.map(OutdoorRecords.durationText) ?? "—")
                            stat("Pace", last.distanceMeters >= OutdoorRecords.minimumPaceDistanceMeters
                                 ? last.averagePaceSecondsPerMeter.map { OutdoorRecords.paceText($0, unit: unit) } ?? "—"
                                 : "—")
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }

        if bests.isEmpty {
            LiftCard(title: "Personal bests") {
                Text("Your last route and your best distance, time and pace show up here after your first run, walk or hike.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
            }
        } else {
            LiftCard(title: "Personal bests") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(bests, id: \.type) { best in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(best.count == 1 ? "\(best.type.displayName) · 1 activity"
                                                 : "\(best.type.displayName) · \(best.count) activities")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            HStack(spacing: 0) {
                                stat("Farthest", best.longestDistanceMeters.map { OutdoorRecords.distanceText($0, unit: unit) } ?? "—")
                                stat("Longest", best.longestDuration.map(OutdoorRecords.durationText) ?? "—")
                                stat("Fastest pace", best.fastestPaceSecondsPerMeter.map { OutdoorRecords.paceText($0, unit: unit) } ?? "—")
                            }
                        }
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A route drawn on a map that does not move. Scrolling Train must scroll
/// Train; panning belongs to the review screen the card opens.
private struct RouteMap: View {
    let points: [RoutePoint]

    var body: some View {
        let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        Map(initialPosition: .automatic, interactionModes: []) {
            MapPolyline(coordinates: coordinates)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            if let start = coordinates.first {
                Annotation("Start", coordinate: start, anchor: .center) {
                    Circle().fill(Theme.accentSecondary).frame(width: 10, height: 10)
                }
                .annotationTitles(.hidden)
            }
            if let end = coordinates.last {
                Annotation("Finish", coordinate: end, anchor: .center) {
                    Circle().fill(Theme.accent).frame(width: 12, height: 12)
                }
                .annotationTitles(.hidden)
            }
        }
        .allowsHitTesting(false)
    }
}
