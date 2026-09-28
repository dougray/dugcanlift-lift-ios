import SwiftUI
import SwiftData
import LiftCore

/// What you were asked to do, and what you did -- a week of a coach's plan
/// beside this phone's own log, on Train.
///
/// **Under the coach's own card for the day and above the day's log.** The
/// day's own action still comes first ("Coach scheduled: Lower A" starts it)
/// and the week is the context under it, exactly where LIFT web puts it. The
/// card is a week and not a marker on a day because Train shows one day at a
/// time and cannot be moved past today: a booked Wednesday is invisible on
/// Thursday, and a booked Friday can be looked at nowhere else on the phone.
/// A marker on the day screen would only restate what the day screen already
/// shows.
///
/// **It is absent entirely when the week on screen books no training.** Not an
/// empty frame explaining itself: a lifter who has never been sent a plan
/// should not learn this screen exists by being told it has nothing for them,
/// and a week of their own training held up against a plan nobody wrote would
/// be the app inventing an expectation.
///
/// The rules are all in `PlanAndLog`, where they are tested as strings rather
/// than by an eye on a screen. Nothing is graded here: no score, no
/// percentage, no streak, no colour on a day nothing was logged against.
struct PlanWeekCard: View {
    /// The day Train is showing. The week follows it unless an arrow has moved
    /// the card somewhere else.
    let date: Date
    /// The Monday the card is parked on, or nil for "follow Train".
    @Binding var anchor: String?
    /// The day open, or nil for "whichever day Train is showing".
    @Binding var open: String?
    /// Moves Train to a day the card opened, when Train can show it.
    let show: (String) -> Void

    var body: some View {
        // The week the card is looking at is settled here, so the body below
        // can hold a `@Query` for that week's seven days rather than for every
        // day this phone has ever logged.
        PlanWeekBody(week: anchor ?? DayKey.make(from: date),
                     trainKey: DayKey.make(from: date),
                     anchor: $anchor, open: $open, show: show)
    }
}

/// The card itself, for one settled week.
private struct PlanWeekBody: View {
    let anchorKey: String
    let trainKey: String
    @Binding var anchor: String?
    @Binding var open: String?
    let show: (String) -> Void

    @AppStorage("weightUnit") private var unitRaw = WeightUnit.pounds.rawValue
    @AppStorage(PlanSides.storageKey) private var planSidesData = Data()
    // Which planned meals a coach booked (`PlanMeals`). `@AppStorage` rather than
    // a read, so accepting a plan redraws the card with the meals it just booked.
    @AppStorage(PlanMeals.storageKey) private var planMealsData = Data()

    /// Every booking and every routine, not a week's worth: the arrows have to
    /// know which weeks a coach booked at all, and a booking reaches its
    /// routine by id rather than through a relationship. Both tables are small
    /// -- one row per day a coach has ever booked, one per routine in the
    /// library. The log is not: only this week's seven days are fetched.
    @Query private var sessions: [ScheduledSession]
    @Query private var routines: [Routine]
    @Query private var days: [WorkoutDay]
    /// Every planned meal, for the reason every booking is fetched: the arrows
    /// have to know which weeks a coach booked food in, and a week of meals is a
    /// card of its own. One row per meal anybody has planned, a coach's and this
    /// phone's own -- which of the two each is, is `PlanAndLog.bookedMeals`'s
    /// decision and not a fetch's.
    @Query private var plannedMeals: [PlannedMeal]

    init(week anchorKey: String, trainKey: String, anchor: Binding<String?>,
         open: Binding<String?>, show: @escaping (String) -> Void) {
        self.anchorKey = anchorKey
        self.trainKey = trainKey
        self._anchor = anchor
        self._open = open
        self.show = show
        let keys = PlanAndLog.dayKeys(of: anchorKey)
        _days = Query(filter: #Predicate<WorkoutDay> { keys.contains($0.dayKey) })
    }

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .pounds }

    private var sides: PlanSides {
        (try? JSONDecoder().decode(PlanSides.self, from: planSidesData)) ?? PlanSides()
    }

    /// Decoded once per body evaluation and threaded down, rather than per row.
    private var meals: [PlanAndLog.Meal] {
        let coach = (try? JSONDecoder().decode(PlanMeals.self, from: planMealsData)) ?? PlanMeals()
        return PlanAndLog.meals(plannedMeals, coach: coach)
    }

    private var week: PlanAndLog.Result? {
        PlanAndLog.compare(anchor: anchorKey, today: DayKey.today,
                           sessions: sessions, routines: routines, days: days,
                           meals: meals, sides: sides, unit: unit)
    }

    var body: some View {
        if let week {
            LiftCard {
                VStack(alignment: .leading, spacing: 10) {
                    sentBy(week)
                    head(week)
                    ForEach(week.days) { day in
                        dayRow(day, openKey: openKey(in: week))
                    }
                    Text(week.footer)
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 2)
                }
            }
            // A plan arriving brings the card back to the day on screen: it was
            // very likely parked on an older week, and the week that just
            // arrived is the one being asked about. Meals as well as sessions,
            // because a plan can book only food and that is a week too.
            .onChange(of: sessions.count) { anchor = nil; open = nil }
            .onChange(of: plannedMeals.count) { anchor = nil; open = nil }
        }
    }

    /// Exactly one day is open, and by default it is the day the rest of Train
    /// is showing -- so the card follows the screen rather than keeping a
    /// second idea of where you are.
    private func openKey(in week: PlanAndLog.Result) -> String? {
        if let open { return open }
        return week.days.contains(where: { $0.key == trainKey }) ? trainKey : nil
    }

    // MARK: Who sent it

    /// One muted line above the head -- the coach's name when a plan this week
    /// carried one, "From your coach" when none did. Exactly where LIFT web
    /// puts it, and the only place a name appears on this card: the rows
    /// below are about a week, not about who wrote it.
    ///
    /// `Text` is handed a `String` and never a literal with a name
    /// interpolated into it. A literal is a `LocalizedStringKey`, which is
    /// read as Markdown -- and `n` is free text typed into somebody else's
    /// app. Two lines at most, so a coach with a very long name pushes
    /// nothing off the card.
    private func sentBy(_ week: PlanAndLog.Result) -> some View {
        Text(PlanAndLog.sentBy(week, sessions: sessions, meals: meals))
            .font(Theme.detail)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(2)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The week's head, and its arrows

    private func head(_ week: PlanAndLog.Result) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            step("chevron.left", direction: -1, from: week.from)
            Text(week.head)
                .font(Theme.sectionLabel)
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(week.spokenHead)
            step("chevron.right", direction: 1, from: week.from)
        }
    }

    /// The arrows move between weeks a coach actually booked, not one week at a
    /// time: a card that vanished on the way to an empty week would take its
    /// own arrows with it and leave no way back. An arrow with nothing behind
    /// it is disabled rather than hidden, so the row does not change shape as
    /// it is used.
    private func step(_ symbol: String, direction: Int, from monday: String) -> some View {
        let target = PlanAndLog.adjacentWeek(
            bookedDates: PlanAndLog.bookedDates(sessions: sessions, meals: meals),
            from: monday, direction: direction)
        return Button {
            anchor = target
            open = nil
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(target == nil ? Theme.textSecondary : Theme.accent)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .accessibilityLabel(direction < 0 ? "Previous booked week" : "Next booked week")
    }

    // MARK: One day

    @ViewBuilder
    private func dayRow(_ day: PlanAndLog.DayRow, openKey: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Theme.hairline)

            Button {
                open = day.key
                // A day Train can show moves Train to it. A day that has not
                // happened cannot be shown there, which is exactly why its
                // prescription is printed here instead.
                if day.openable {
                    show(day.key)
                    anchor = nil
                }
            } label: {
                // Every verdict in the same weight and the same colour. A day
                // nothing was logged against is not emphasised, and nothing is
                // coloured: a macro goal is a number on a dial, a booked
                // session is a person's week.
                Text(day.text)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            // One name for the row, not three fragments -- and the two things
            // pressing it does. The trait says it is a button; nothing on
            // screen said which state it is in, or that opening a day Train
            // can show also moves Train there.
            .accessibilityLabel(day.spoken)
            .accessibilityValue(day.key == openKey ? "Expanded" : "Collapsed")
            .accessibilityHint(day.openable ? "Opens this day on Train" : "Opens this day")

            if day.key == openKey { detail(day) }
        }
    }

    /// One day opened out: the lifts, what each asked for and what came back,
    /// and anything logged that nothing asked for.
    @ViewBuilder
    private func detail(_ day: PlanAndLog.DayRow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(day.exercises, id: \.key) { exercise in
                // **Drawn as it always was and said as one sentence.** Every
                // `Text` in a `VStack` is its own accessibility element, so the
                // six lines of a lift arrive as six stops with the word that
                // named the numbers two swipes behind them. One element with
                // the rule's own sentence makes the asked row and the logged
                // row the comparison they are.
                VStack(alignment: .leading, spacing: 3) {
                    Text(exercise.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    if let side = exercise.sideLine { muted(side) }
                    if let count = exercise.countLine { muted(count) }
                    if let asked = exercise.asked { setRow(asked) }
                    if let logged = exercise.logged { setRow(logged) }
                    // Under the pair, where it says what the two rows above it
                    // are; it reads as nonsense above them.
                    if let substitution = exercise.substitution { muted(substitution) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(exercise.spoken)
            }
            if !day.alsoLogged.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Also logged")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    ForEach(day.alsoLogged, id: \.key) { row in
                        muted(row.text).accessibilityLabel(row.spoken)
                    }
                }
            }
            mealsBlock(day)
        }
        .padding(.leading, 2)
        .padding(.bottom, 2)
    }

    /// What a coach booked for this day to eat, under the training it sits beside.
    ///
    /// **Stated and nothing more** -- no verdict per slot, no macros, and nothing
    /// at all about what was logged, however much this device knows. `PlanAndLog`
    /// says at length why. The slot and the dish are `MealRow`'s own two columns,
    /// so Breakfast and Dinner line up with each other and this composes no
    /// sentence of its own; the column is wider than `setRow`'s, which holds
    /// "Asked" and not "Breakfast".
    ///
    /// Keyed by position, because two dishes at one dinner can be the same dish
    /// twice and both are shown.
    @ViewBuilder
    private func mealsBlock(_ day: PlanAndLog.DayRow) -> some View {
        if !day.meals.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Meals")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                ForEach(Array(day.meals.enumerated()), id: \.offset) { _, meal in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(meal.slotLabel)
                            .font(Theme.detail)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 76, alignment: .leading)
                        Text(meal.detail)
                            .font(Theme.detail)
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // One sentence for the pair, the way an asked/logged pair
                    // is one: each `Text` is its own element, so read as drawn
                    // this is "Breakfast", then "Overnight Oats · 1 serving"
                    // with the dot spelled out. `PlanAndLog.spokenLines` says
                    // the same sentence.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(PlanAndLog.plainly(meal.title))
                }
            }
        }
    }

    /// One row of sets: "Asked   L 40 x 8 · 40 x 8   R 40 x 8".
    ///
    /// The groups **and** the suffix, always. "each side" is a clause on the
    /// ask rather than a set of its own, and a row that drew the groups and
    /// dropped it would print a plan asking for half of what it asks for.
    private func setRow(_ row: PlanAndLog.SetRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.label)
                .font(Theme.detail)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 52, alignment: .leading)
            Text(row.text)
                .font(Theme.detail)
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func muted(_ text: String) -> some View {
        Text(text)
            .font(Theme.detail)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
