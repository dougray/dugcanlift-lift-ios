import Foundation
import LiftCore

/// What you were asked to do, and what you did.
///
/// A coach's plan and this phone's log have always been two separate records
/// -- `ScheduledSession` plus the `Routine` behind it is what was sent,
/// `WorkoutDay` is what happened -- and they have been shown side by side
/// nowhere. Train shows **one day at a time** and its Next button is disabled
/// past today, so a booked Wednesday is invisible on Thursday and a booked
/// Friday cannot be looked at anywhere on the phone. That is why this is a
/// **week** and not a marker on a day: the days a lifter cannot reach are the
/// ones they most need to see mid-week, and a marker on the day screen would
/// only restate what the day screen already shows.
///
/// A value type with no view in it, for the reason `LiftProgression`,
/// `RoutineRemoval` and `OutdoorRemoval` are: a rule in a view's `@State`
/// cannot be tested, and this one decides what somebody is told about their
/// own week. **LIFT web's `lift/plan-log.js` is the reference
/// implementation**, as `sides.js` is; this is a port of it, and
/// `PlanAndLogTests` ports its cases.
///
/// **Nothing new travels and nothing new is stored.** No wire change, no new
/// key, no new permission, no schema change: the accepted plan and the log are
/// read exactly as they already sit in the store, and a log a coach never
/// receives is compared just the same. This is your copy of your own week.
///
/// **You are not being graded.** No score, no percentage, no streak, no colour
/// on a day nothing was logged against, and nothing that carries from one week
/// to the next. `lines(_:)` exists so that is testable as strings rather than
/// left to an eye on a screen -- the house rule, tracked and shown never
/// targeted, applies here with more force than anywhere else in the app,
/// because this is the screen most likely to drift into nagging.
///
/// **The words are Coach's, where the fact is the same one.** A coach reading
/// `Fri 17 Oct · Upper B · not logged` about a client and a lifter reading it
/// about themselves are reading the same fact, and describing a week to each
/// other is easier when the app describes it the same way to both. Coach's
/// `not logged`, `not booked`, `Asked` / `Logged`, the side counts and the
/// count line are reused unchanged. Two things deliberately are not:
///
///   - `outside the log they sent` -- Coach's fourth state, which exists
///     because a client sends a window and a booked day can fall outside it.
///     The log is right here. The state cannot arise and the sentence does not
///     exist.
///   - Coach's footer -- "whether it arrived, and whether they opened it, only
///     they know" is a sentence about somebody else. This card's footer is the
///     same thought pointed the other way.
///
/// And one state is new, because only the person living the week has it: `to
/// do`. A booked day that has not happened yet is not an absence, and calling
/// it one would be the app inventing a failure out of a Wednesday.
///
/// **The ask is read from the stored plan, never from the logged sets.**
/// Starting a booked session copies its two-sided prescribed sets in as
/// editable sets, and `PlanSides.logged` keeps a prescription beside a logged
/// exercise **only when that prescription says something about sides** -- so
/// for an ordinary plan the original ask is gone from the log the moment a set
/// is edited, which is precisely the difference this card is for. What was
/// asked comes from `ScheduledSession` and the `Routine` it booked (see
/// `PlanAndLogStore.swift`); what came back comes from `WorkoutDay`.
///
/// **Both rows are kilograms**, the only unit this app stores, converted once
/// for display through `WeightUnit` exactly as `SetEntry.display` does --
/// which is also what `setText` reproduces, so a set cannot read one way in
/// the day editor and another way here.
enum PlanAndLog {

    /// Coach's footer is about somebody else. This is the same thought pointed
    /// the other way, and it is the whole discipline of the card in one
    /// sentence: it holds two records and knows nothing about the week that
    /// produced them. A day nothing was logged against may have been a day you
    /// trained and did not log, a day you were ill, or a day you were told to
    /// rest, and the only person who can tell those apart is reading it.
    static let footer = "Your coach’s plan beside your own log. What else the week "
        + "held, only you know."

    /// Monday. A coach writes weeks, so a rolling seven days would move a
    /// booked Tuesday from "this week" to "last week" overnight and describe
    /// the same plan two different ways on two consecutive days. A fixed
    /// constant rather than the reader's locale, so the week a lifter sees is
    /// the week their coach wrote wherever either of them happens to be.
    static let weekStartsOn = 2   // Calendar's Monday: 1 is Sunday.

    // MARK: - What goes in

    /// One prescribed or logged set, in the same shape -- PLAN-FORMAT's set
    /// tuple and SHARE-FORMAT's are deliberately the same six fields "so
    /// nothing has to be transposed to compare what was asked for against what
    /// was done", and one row sitting above the other is what that was written
    /// for.
    ///
    /// Every field optional, because **blank stays blank**: a prescribed
    /// `[null, 5]` is "5 reps", never "0 x 5", and a logged set's zero weight
    /// is the same absence `SetEntry.display` already reads it as.
    struct SetValues: Equatable {
        var weightKg: Double?
        var reps: Int?
        var rpe: Double?
        var durationSec: Int?
        var distanceMeters: Double?
        var side: SetSide?

        init(weightKg: Double? = nil, reps: Int? = nil, rpe: Double? = nil,
             durationSec: Int? = nil, distanceMeters: Double? = nil, side: SetSide? = nil) {
            self.weightKg = weightKg
            self.reps = reps
            self.rpe = rpe
            self.durationSec = durationSec
            self.distanceMeters = distanceMeters
            self.side = side
        }
    }

    /// A lift on either side of the join, its sets pooled.
    struct Exercise: Equatable {
        var key: String
        var name: String
        var equipment: String
        var eachSide: Bool
        var sets: [SetValues]

        init(key: String? = nil, name: String, equipment: String,
             eachSide: Bool = false, sets: [SetValues]) {
            self.key = key ?? PlanAndLog.matchKey(name: name, equipment: equipment)
            self.name = name
            self.equipment = equipment
            self.eachSide = eachSide
            self.sets = sets
        }
    }

    /// One session a coach booked on one date -- a `ScheduledSession` and the
    /// routine behind it. Two booked on one date pool into one day's ask, as
    /// two logged sessions would.
    struct Booking: Equatable {
        var date: String
        var name: String
        /// The coach who sent it, from the plan's `n` -- read by `sentBy` and
        /// by nothing else. Nil when the plan named nobody, and on every
        /// booking accepted before a booking kept the name at all.
        var coachName: String?
        var exercises: [Exercise]

        init(date: String, name: String, coachName: String? = nil,
             exercises: [Exercise]) {
            self.date = date
            self.name = name
            self.coachName = coachName
            self.exercises = exercises
        }
    }

    /// A day this phone logged. One per date -- a `WorkoutDay` *is* the day,
    /// which is why nothing here has to pick a session out of one (see
    /// `compare`).
    struct LoggedDay: Equatable {
        var date: String
        var name: String
        var exercises: [Exercise]

        init(date: String, name: String = "", exercises: [Exercise]) {
            self.date = date
            self.name = name
            self.exercises = exercises
        }
    }

    // MARK: - What comes out

    enum DayState: String, Equatable { case logged, toDo, notLogged, notBooked }
    enum ExerciseState: String, Equatable { case logged, toDo, notLogged }

    /// One side's sets -- "L 40 x 8 · 40 x 8 · 40 x 5" -- or one unlabelled
    /// group when nothing is sided.
    struct SetGroup: Equatable {
        var label: String
        var text: String
        /// The same sets, said: ` x ` read as "by" and the separators as
        /// commas.
        var spoken: String = ""
    }

    /// An Asked or a Logged row. `suffix` carries "each side", which is a
    /// clause on the ask and not a set of its own: a view that drew the groups
    /// and forgot the clause would print a plan asking for half of what it
    /// asks for.
    struct SetRow: Equatable {
        var label: String
        var groups: [SetGroup]
        var suffix: String
        var text: String
        /// The label **and** the groups in one string: read apart, "Asked" and
        /// a list of numbers are two announcements with no relationship.
        var spoken: String = ""
    }

    struct ExerciseRow: Equatable {
        var key: String
        /// The lift on its own, for a heading that is about the lift and not
        /// about one day of it.
        var lift: String
        var title: String
        var state: ExerciseState
        var substitution: String?
        var sideLine: String?
        /// `sideLine` said: "L 3/3 · R 2/3" is a column heading read literally.
        var spokenSideLine: String?
        var countLine: String?
        var asked: SetRow?
        var logged: SetRow?

        /// The whole block as one announcement.
        ///
        /// **The two rows are a comparison, and read apart they are two lists
        /// of numbers with nothing between them.** One element carrying the
        /// lift and both rows is what makes the relationship audible.
        var spoken: String {
            ([PlanAndLog.plainly(title)] + spokenDetailParts).joined(separator: ". ")
        }

        private var spokenDetailParts: [String] {
            [spokenSideLine,
             countLine.map(PlanAndLog.plainly),
             asked?.spoken,
             logged?.spoken,
             substitution.map(PlanAndLog.plainly)]
                .compactMap { $0 }.filter { !$0.isEmpty }
        }
    }

    /// A lift the log has and the plan does not: its name and how many working
    /// sets it carried, counted against nothing.
    struct AlsoLoggedRow: Equatable {
        var key: String
        var title: String
        var text: String
        var spoken: String { PlanAndLog.plainly(text) }
    }

    /// The days this week booked and the days it holds, and nothing else. No
    /// all-time figure, no trend, nothing carried to next week.
    struct Counts: Equatable {
        var booked = 0
        var logged = 0
        var notLogged = 0
        var toDo = 0
        var other = 0
    }

    struct DayRow: Equatable, Identifiable {
        var key: String
        var state: DayState
        var name: String
        var text: String
        /// `text` said: three clauses separated by ` · ` are three fragments
        /// to a screen reader, and a day row is one thing you read.
        var spoken: String = ""
        /// Whether Train can be moved to this day. Past or today; a day still
        /// ahead cannot be opened there, which is the reason its prescription
        /// is printed here instead.
        var openable: Bool
        var exercises: [ExerciseRow]
        var alsoLogged: [AlsoLoggedRow]

        var id: String { key }
    }

    struct Result: Equatable {
        var from: String
        var to: String
        var range: String
        var counts: Counts
        var head: String
        /// `head` with the range said as a range: "28 Sep–4 Oct" is a dash and
        /// two abbreviations aloud.
        var spokenHead: String = ""
        var days: [DayRow]
        var footer: String
    }

    // MARK: - The week

    /// The [Monday, Sunday] containing a day key.
    static func weekOf(_ key: String) -> (from: String, to: String) {
        guard let weekday = weekdayIndex(key) else { return (key, key) }
        let back = (weekday - weekStartsOn + 7) % 7
        let from = shift(key, by: -back)
        return (from, shift(from, by: 6))
    }

    /// The seven day keys of the week containing a day, Monday first. What a
    /// view fetches its log for: the card reads one week and no more.
    static func dayKeys(of key: String) -> [String] {
        let from = weekOf(key).from
        return (0...6).map { shift(from, by: $0) }
    }

    /// The Monday of the nearest week in `direction` (-1 back, +1 on) that
    /// books something, or nil when there is none.
    ///
    /// Paging moves between weeks a coach actually wrote, never one week at a
    /// time. A card that vanished on the way to an empty week would take its
    /// own arrows with it and leave no way back, which is the one thing worse
    /// than an empty frame; and an arrow with nothing behind it is disabled
    /// rather than hidden, so the row does not change shape as it is used.
    static func adjacentWeek(bookedDates: [String], from monday: String,
                             direction: Int) -> String? {
        let weeks = Set(bookedDates.map { weekOf($0).from }).sorted()
            .filter { direction < 0 ? $0 < monday : $0 > monday }
        return direction < 0 ? weeks.last : weeks.first
    }

    // MARK: - The join

    /// One week of a coach's plan against this device's log, or `nil` when
    /// there is nothing to say.
    ///
    /// `nil` -- not an empty card, not an explanation -- whenever the week the
    /// card is looking at books no training. A lifter who has never been sent
    /// a plan should not learn that this screen exists by being told it has
    /// nothing for them, and a week of your own training held up against a
    /// plan nobody wrote is the app inventing an expectation.
    ///
    /// **Days join on date, and nothing else.** A session lifted the day after
    /// the one it was booked for is a booked day with nothing logged **and** a
    /// session of its own; the two sit next to each other on screen and
    /// nothing here claims a connection between them. LIFT web uses
    /// `startedSessionId` to pick the right session out of a day that holds
    /// two -- this app has no session below the day at all (`WorkoutDay` is
    /// one per date, `dayKey` unique), so there is nothing to pick: everything
    /// logged that day is that day's log, and a lift nobody asked for falls to
    /// `Also logged` exactly as it does in the browser.
    static func compare(bookings: [Booking], logged: [LoggedDay],
                        today: String, anchor: String,
                        unit: WeightUnit, locale: Locale = .current) -> Result? {
        let week = weekOf(anchor)
        let booked = bookings.filter { $0.date >= week.from && $0.date <= week.to }
        guard !booked.isEmpty else { return nil }

        let days = logged.filter { $0.date >= week.from && $0.date <= week.to }
        var byDate: [String: [Booking]] = [:]
        for booking in booked { byDate[booking.date, default: []].append(booking) }
        var loggedByDate: [String: LoggedDay] = [:]
        for day in days {
            if var existing = loggedByDate[day.date] {
                existing.exercises = pooled(existing.exercises + day.exercises)
                loggedByDate[day.date] = existing
            } else {
                loggedByDate[day.date] = LoggedDay(date: day.date, name: day.name,
                                                   exercises: pooled(day.exercises))
            }
        }

        var counts = Counts()
        counts.booked = byDate.count
        var rows: [DayRow] = byDate.keys.sorted().map { date in
            let booking = merge(byDate[date] ?? [], on: date)
            let day = loggedByDate[date]

            let state: DayState
            if !(day?.exercises.isEmpty ?? true) {
                state = .logged; counts.logged += 1
            } else if date >= today {
                state = .toDo; counts.toDo += 1
            } else {
                state = .notLogged; counts.notLogged += 1
            }

            let word = self.word(for: state)
            let joined: (exercises: [ExerciseRow], alsoLogged: [AlsoLoggedRow])
            switch state {
            case .logged:
                joined = join(asked: booking.exercises, logged: day?.exercises ?? [],
                              unit: unit)
            default:
                // A day still ahead prints what it asks for, because nowhere
                // else can. A day in the past does not recite what was not
                // done: it is one tap away and its own booking still holds
                // every set.
                joined = (booking.exercises.map {
                    pairRow(asked: $0, logged: nil, substituted: false, unit: unit,
                            absentWord: state == .toDo ? "" : word, recite: state == .toDo)
                }, [])
            }

            return DayRow(
                key: date, state: state, name: booking.name,
                text: [dayLabel(date, locale: locale), booking.name, word]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                // The same clauses, in the same order, with the date said in
                // words -- one sentence rather than three fragments. Built
                // here beside `text` rather than from it, so a clause can
                // never be in one and not the other.
                spoken: said([spokenDayLabel(date, locale: locale), booking.name, word]),
                openable: date <= today,
                exercises: joined.exercises, alsoLogged: joined.alsoLogged)
        }

        // A day in the week that was trained and that nothing was booked for.
        // Shown beside the bookings, saying nothing about cause: a session
        // lifted the day after the one it was booked for looks exactly like
        // this, and so does a session added for its own sake.
        for day in loggedByDate.values.sorted(by: { $0.date < $1.date })
        where byDate[day.date] == nil && !day.exercises.isEmpty {
            counts.other += 1
            rows.append(DayRow(
                key: day.date, state: .notBooked, name: day.name,
                text: [dayLabel(day.date, locale: locale), day.name, word(for: .notBooked)]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                spoken: said([spokenDayLabel(day.date, locale: locale), day.name,
                              word(for: .notBooked)]),
                openable: day.date <= today,
                exercises: [],
                alsoLogged: day.exercises.filter { !$0.sets.isEmpty }.map(alsoLoggedRow)))
        }
        rows.sort { $0.key < $1.key }

        let range = rangeText(from: week.from, to: week.to, locale: locale)
        return Result(from: week.from, to: week.to, range: range, counts: counts,
                      head: headLine(range: range, counts: counts),
                      spokenHead: plainly(headLine(
                          range: spokenRange(from: week.from, to: week.to, locale: locale),
                          counts: counts)),
                      days: rows,
                      footer: footer)
    }

    /// One date's whole ask, from however many sessions were booked on it.
    ///
    /// **The lifts pool**, whether they came from one booking or two -- the
    /// same lift asked for twice in a day is one lift of more sets, exactly as
    /// two logged sessions of it pool. The wire forces half of that already:
    /// SHARE-FORMAT gives a day one `w` array, so a log arriving at a coach has
    /// its sessions merged before the coach sees it, and the asked side has to
    /// be read the same way.
    ///
    /// A name repeated across two bookings is said once. Two `ScheduledSession`
    /// rows naming the same routine on one date is a coach's plan re-sent or
    /// booked twice, and `Lower A · Lower A` would read as a mistake rather
    /// than as a fact -- the call Coach's own card makes.
    private static func merge(_ list: [Booking], on date: String) -> Booking {
        var names: [String] = []
        for name in list.map(\.name) where !name.isEmpty && !names.contains(name) {
            names.append(name)
        }
        return Booking(date: date, name: names.joined(separator: " · "),
                       exercises: pooled(list.flatMap(\.exercises)))
    }

    /// Exercises pooled by name and equipment, keeping first-seen order. The
    /// same lift asked for twice in a day, or logged twice in a day, is one
    /// lift of more sets.
    static func pooled(_ list: [Exercise]) -> [Exercise] {
        var order: [String] = []
        var byKey: [String: Exercise] = [:]
        for exercise in list {
            if byKey[exercise.key] == nil {
                byKey[exercise.key] = Exercise(key: exercise.key, name: exercise.name,
                                               equipment: exercise.equipment,
                                               eachSide: exercise.eachSide, sets: [])
                order.append(exercise.key)
            }
            // Each side is a property of the lift, not of one booking of it.
            if exercise.eachSide { byKey[exercise.key]?.eachSide = true }
            byKey[exercise.key]?.sets.append(contentsOf: exercise.sets)
        }
        return order.compactMap { byKey[$0] }
    }

    /// The asked and the logged exercises of one day, joined.
    ///
    /// Two passes, in this order, so an exact match always wins:
    ///   1. name and equipment -- a cable pulldown and a machine pulldown are
    ///      not the same lift, and a coach prescribing one of them meant it.
    ///   2. name alone, over what is left on each side: the equipment
    ///      substitution, paired and labelled.
    /// Never by position: skipping the second exercise would shift every
    /// pairing after it.
    private static func join(asked: [Exercise], logged: [Exercise],
                             unit: WeightUnit) -> (exercises: [ExerciseRow],
                                                   alsoLogged: [AlsoLoggedRow]) {
        var remaining = logged
        func take(_ matches: (Exercise) -> Bool) -> Exercise? {
            guard let index = remaining.firstIndex(where: matches) else { return nil }
            return remaining.remove(at: index)
        }

        var pairs: [(asked: Exercise, logged: Exercise?, substituted: Bool)] =
            asked.map { exercise in (exercise, take { $0.key == exercise.key }, false) }
        for index in pairs.indices where pairs[index].logged == nil {
            let wanted = nameKey(pairs[index].asked.name)
            if let match = take({ nameKey($0.name) == wanted }) {
                pairs[index].logged = match
                pairs[index].substituted = true
            }
        }

        return (
            exercises: pairs.map {
                pairRow(asked: $0.asked, logged: $0.logged, substituted: $0.substituted,
                        unit: unit, absentWord: "not logged", recite: false)
            },
            // Working sets are the claim everywhere else here, so a lift
            // nobody asked for that was all warmups is not "0 sets" on screen.
            alsoLogged: remaining.filter { !$0.sets.isEmpty }.map(alsoLoggedRow))
    }

    private static func alsoLoggedRow(_ exercise: Exercise) -> AlsoLoggedRow {
        AlsoLoggedRow(key: exercise.key, title: title(exercise),
                      text: title(exercise) + " · "
                          + plural(exercise.sets.count, "set", "sets"))
    }

    /// One lift's two rows.
    ///
    /// `recite` is whether the prescription is printed under a lift nothing
    /// has been logged against. True for a day still ahead -- that is the
    /// work, and Train cannot be moved to a day that has not happened, so this
    /// card is the only place it can be read -- and false for a day in the
    /// past, where reciting what was asked for under a day nothing was logged
    /// on turns a fact into a list of what someone did not do.
    private static func pairRow(asked: Exercise, logged: Exercise?, substituted: Bool,
                                unit: WeightUnit, absentWord: String,
                                recite: Bool) -> ExerciseRow {
        let side = sideLine(asked: asked, logged: logged)
        let askedSets = asked.sets
        let loggedSets = logged?.sets ?? []
        let lift = title(asked) + (asked.eachSide ? " · each side" : "")

        var row = ExerciseRow(
            key: asked.key, lift: lift, title: lift,
            state: logged != nil ? .logged : (recite ? .toDo : .notLogged),
            substitution: substituted && logged != nil
                ? "Asked \(equipmentWord(asked.equipment)) · logged "
                    + equipmentWord(logged?.equipment ?? "")
                : nil,
            sideLine: side ?? (recite ? askLine(asked) : nil),
            spokenSideLine: spokenSideLine(asked: asked, logged: logged)
                ?? (recite ? spokenAskLine(asked) : nil),
            countLine: nil,
            asked: (logged != nil || recite) && !askedSets.isEmpty
                ? setRow(label: "Asked", sets: askedSets, unit: unit,
                         suffix: asked.eachSide ? " each side" : "")
                : nil,
            logged: logged != nil
                ? setRow(label: "Logged", sets: loggedSets, unit: unit, suffix: "")
                : nil)

        // How many were asked for and how many came back, when they differ and
        // there is no side line already saying it per side.
        if logged != nil, side == nil, askedSets.count != loggedSets.count {
            row.countLine = "Asked \(plural(askedSets.count, "set", "sets"))"
                + " · logged \(loggedSets.count)"
        }
        if logged == nil, !absentWord.isEmpty { row.title += " · " + absentWord }
        return row
    }

    private static func setRow(label: String, sets: [SetValues], unit: WeightUnit,
                               suffix: String) -> SetRow {
        let groups = setGroups(sets, unit: unit)
        return SetRow(label: label, groups: groups, suffix: suffix,
                      text: groupsText(groups) + suffix,
                      spoken: label + " " + groupsSpoken(groups) + suffix)
    }

    // MARK: - Sides

    /// The side counts the session header has shown since per-side
    /// prescriptions shipped: "L 3/3 · R 2/3", logged over asked, over never
    /// capped, an each-side exercise's ask twice its tuples.
    /// `Prescription.targetsLabel` **is** that header, called with the same
    /// argument it is called with there, so this card and the exercise block it
    /// describes can never disagree about a side. A prescription that says
    /// nothing about sides returns "" and this falls back to the plain count,
    /// exactly as the header does.
    private static func sideLine(asked: Exercise, logged: Exercise?) -> String? {
        guard let logged else { return nil }
        let sides = logged.sets.map(\.side)
        let label = prescription(of: asked).targetsLabel(logged: sides)
        if !label.isEmpty { return label }
        return sides.contains(where: { $0 != nil }) ? SetSide.countsLabel(of: sides) : nil
    }

    /// `sideLine`, said -- the same two functions' own spoken forms, called
    /// with the same argument in the same order, so this card and the exercise
    /// block it describes can no more disagree about a side aloud than they
    /// can on screen.
    private static func spokenSideLine(asked: Exercise, logged: Exercise?) -> String? {
        guard let logged else { return nil }
        let sides = logged.sets.map(\.side)
        let spoken = prescription(of: asked).targetsSpoken(logged: sides)
        if !spoken.isEmpty { return spoken }
        return sides.contains(where: { $0 != nil }) ? SetSide.countsSpoken(of: sides) : nil
    }

    /// What an each-side lift asks for, on a day nothing has been logged
    /// against yet: "Each side · L 4 · R 3".
    ///
    /// Deliberately not `targetsLabel`, which would read "L 0/3 · R 0/3" --
    /// true during a session, and on a day still ahead a zero nobody has had
    /// the chance to earn. Blank stays blank; a week that has not happened is
    /// not a week of noughts.
    private static func askLine(_ asked: Exercise) -> String? {
        guard asked.eachSide else { return nil }
        let targets = prescription(of: asked).targets
        return "Each side · L \(targets.left) · R \(targets.right)"
    }

    /// `askLine`, said.
    private static func spokenAskLine(_ asked: Exercise) -> String? {
        guard asked.eachSide else { return nil }
        let targets = prescription(of: asked).targets
        return "Each side, left \(targets.left), right \(targets.right)"
    }

    /// The ask as the session header reads one. Only the sides are read from
    /// it, so nothing here has to carry a weight twice.
    private static func prescription(of asked: Exercise) -> Prescription {
        Prescription(eachSide: asked.eachSide,
                     sets: asked.sets.map { CoachPrescribedSet(side: $0.side) })
    }

    // MARK: - How a set reads

    /// Sets as one group per side -- "L 40 x 8 · 40 x 8 · 40 x 5" beside
    /// "R 40 x 8 · 40 x 8" -- or a single unlabelled group when nothing is
    /// sided.
    ///
    /// Sets are listed, never paired one to one with the row above. If three
    /// of four sets came back, nothing here can say which one was dropped, so
    /// nothing here says.
    static func setGroups(_ sets: [SetValues], unit: WeightUnit) -> [SetGroup] {
        guard sets.contains(where: { $0.side != nil }) else {
            return sets.isEmpty ? [] : [SetGroup(
                label: "",
                text: sets.map { setText($0, unit: unit) }.joined(separator: " · "),
                spoken: sets.map { spokenSetText($0, unit: unit) }.joined(separator: ", "))]
        }
        var groups: [SetGroup] = []
        for side in [SetSide.left, .right, nil] {
            let mine = sets.filter { $0.side == side }
            guard !mine.isEmpty else { continue }
            groups.append(SetGroup(
                label: side?.shortLabel ?? "Both",
                text: mine.map { setText($0, unit: unit) }.joined(separator: " · "),
                spoken: mine.map { spokenSetText($0, unit: unit) }.joined(separator: ", ")))
        }
        return groups
    }

    static func groupsText(_ groups: [SetGroup]) -> String {
        groups.map { ($0.label.isEmpty ? "" : $0.label + " ") + $0.text }
            .joined(separator: "   ")
    }

    /// The groups said, one limb after the other. A semicolon between them,
    /// because the sets inside a group are already separated by commas and
    /// "right" has to land as a new column.
    static func groupsSpoken(_ groups: [SetGroup]) -> String {
        groups.map { ($0.label.isEmpty ? "" : sideWord($0.label) + " ") + $0.spoken }
            .joined(separator: "; ")
    }

    /// One set, asked or logged, in the same shape: "225 x 5 @8", "5 reps",
    /// "1.60 km 10:00".
    ///
    /// **The same shape, and the same spelling the rest of the app uses.**
    /// `SetEntry.display` is what a set reads as in the day editor, a day
    /// summary and a widget, and this reproduces it field for field --
    /// `SetDisplayParityTests` pins that spelling and `PlanAndLogTests` pins
    /// this against it. A card comparing two rows printed by two different
    /// formatters would be comparing two different sentences.
    ///
    /// The side is deliberately not here: sets are grouped by side (see
    /// `setGroups`), and a set carrying its own "L" inside a group already
    /// labelled "L" would say it twice. `SetEntry.display` adds it for the
    /// flat list in the day editor, which is not grouped.
    ///
    /// Weights are kilograms, the only unit this app stores, converted for
    /// display here and nowhere else. **Blank stays blank**: a prescribed
    /// `[null, 5]` is "5 reps", never "0 x 5".
    static func setText(_ set: SetValues, unit: WeightUnit) -> String {
        var parts: [String] = []
        let weight = set.weightKg.map(unit.fromKilograms)
        let weightText = weight.map {
            $0 == $0.rounded() ? String(Int($0)) : String(format: "%.1f", $0)
        }
        if let weightText, let reps = set.reps {
            parts.append("\(weightText) x \(reps)")
        } else if let weightText {
            parts.append("\(weightText) \(unit.abbreviation)")
        } else if let reps = set.reps {
            parts.append("\(reps) reps")
        }
        if let rpe = set.rpe {
            parts.append("@" + (rpe == rpe.rounded() ? String(Int(rpe))
                                                     : String(format: "%.1f", rpe)))
        }
        if let durationSec = set.durationSec { parts.append(SetMetrics.clock(durationSec)) }
        if let distanceMeters = set.distanceMeters {
            parts.append(SetMetrics.distance(distanceMeters))
        }
        return parts.isEmpty ? "as written" : parts.joined(separator: " ")
    }

    /// The same set, said. The ` x ` is the only difference that matters: it
    /// is the letter, and "225 by 5" is what a lifter says out loud anyway.
    static func spokenSetText(_ set: SetValues, unit: WeightUnit) -> String {
        var parts: [String] = []
        let weight = set.weightKg.map(unit.fromKilograms)
        let weightText = weight.map {
            $0 == $0.rounded() ? String(Int($0)) : String(format: "%.1f", $0)
        }
        if let weightText, let reps = set.reps {
            parts.append("\(weightText) by \(reps)")
        } else if let weightText {
            parts.append("\(weightText) \(unit.abbreviation)")
        } else if let reps = set.reps {
            parts.append("\(reps) reps")
        }
        if let rpe = set.rpe {
            parts.append("@" + (rpe == rpe.rounded() ? String(Int(rpe))
                                                     : String(format: "%.1f", rpe)))
        }
        if let durationSec = set.durationSec { parts.append(SetMetrics.clock(durationSec)) }
        if let distanceMeters = set.distanceMeters {
            parts.append(SetMetrics.distance(distanceMeters))
        }
        return parts.isEmpty ? "as written" : parts.joined(separator: " ")
    }

    // MARK: - Words

    /// The four verdicts. `logged`, `not logged` and `not booked` are Coach
    /// web's words unchanged, so a lifter and their coach describe the same
    /// week the same way; `to do` is this side's own, because only the person
    /// living the week has a day that has not happened yet.
    static let words: [DayState: String] = [
        .logged: "logged", .toDo: "to do",
        .notLogged: "not logged", .notBooked: "not booked",
    ]

    static func word(for state: DayState) -> String { words[state] ?? "" }

    /// The head of the week.
    ///
    /// `logged N` is printed only once something is behind you: a week booked
    /// entirely in the days ahead would otherwise open with "logged 0", which
    /// is a zero nobody earned. A week that is over prints it whatever it is,
    /// because by then it is a count of a finished thing and the same sentence
    /// a coach reads.
    static func headLine(range: String, counts: Counts) -> String {
        var head = "Booked \(plural(counts.booked, "day", "days")), \(range)"
        if counts.logged > 0 || counts.notLogged > 0 { head += " · logged \(counts.logged)" }
        if counts.toDo > 0 { head += " · \(counts.toDo) to do" }
        if counts.other > 0 {
            head += " · " + plural(counts.other, "other day logged", "other days logged")
        }
        return head
    }

    // MARK: - Who sent the week

    /// The one muted line above the head: "From Dana", or "From your coach"
    /// when no plan this week carried a name.
    ///
    /// A port of LIFT web's `sentBy`, name for name: the distinct names on the
    /// bookings **inside this week**, in the order they first appear, joined
    /// with " · ", and the same fallback sentence the prescribed card has
    /// always opened with. A week holding one named plan and one unnamed one
    /// reads as the named one -- a plan that named nobody says nothing about
    /// who sent the week, rather than adding a second voice to it.
    ///
    /// **Not a field on `Result`.** The card is a week's two records and its
    /// counts and nothing above them, which `testNothingHereAggregatesAWeek
    /// IntoAScore` pins by naming `Result`'s every member; who sent it is a
    /// fact about the plans, not a figure about the week. Web keeps it out of
    /// `compare` for the same reason, and out of `lines` -- the line
    /// discipline is about what the card says of somebody's week, and this
    /// says nothing of it.
    ///
    /// `n` is free text from another person's app. It reaches a screen here,
    /// so a name is trimmed **and its inner whitespace collapsed**: the
    /// browser gets that from HTML, which folds a newline in a `<p>` into a
    /// space, and a SwiftUI `Text` does not -- a name with a line break in it
    /// would otherwise quietly turn one line of card into three.
    static func sentBy(_ result: Result, bookings: [Booking]) -> String {
        var names: [String] = []
        for booking in bookings where booking.date >= result.from && booking.date <= result.to {
            guard let name = coachName(booking.coachName) else { continue }
            if !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? noCoachName : "From " + names.joined(separator: " · ")
    }

    /// What a week whose plans named nobody reads as -- and what every week
    /// booked before a booking kept a name reads as, unchanged.
    static let noCoachName = "From your coach"

    /// A name as it can be printed, or nil when there is nothing to print.
    private static func coachName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func title(_ exercise: Exercise) -> String {
        exercise.equipment.isEmpty ? exercise.name
                                   : "\(exercise.name) (\(exercise.equipment))"
    }

    private static func equipmentWord(_ equipment: String) -> String {
        equipment.isEmpty ? "no equipment" : equipment
    }

    private static func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }

    // MARK: - How a line reads aloud
    //
    // Every line on this card is written with ` · ` between its clauses, which
    // is a comma that takes no vertical space. Aloud it is not a comma:
    // VoiceOver either names the character or passes over it, and either way
    // "Mon 28 Sep · Lower A · logged" arrives as three unrelated fragments. So
    // every line that reaches a screen also carries a spoken form, composed
    // here from the same parts the written one is composed from -- never by a
    // regex over the finished string, which would have to guess whether the
    // `x` in a name you typed is a multiplication sign.
    //
    // ` · ` becomes a comma, ` x ` becomes "by", `L`/`R` become
    // "left"/"right", `3/3` becomes "3 of 3", and an abbreviated date becomes
    // the words a person says. **Nothing else.** No word is added that the
    // card does not draw: you are not being graded here, and a day nothing was
    // logged against is as flat aloud as it is on screen.
    //
    // Here rather than in `PlanWeekCard`, for the reason everything else on
    // this card is here: a sentence you read is a rule, and a rule in a view's
    // `@State` cannot be tested.

    /// ` · ` is the only thing this may touch -- for the lines this type no
    /// longer has the parts of by the time a view asks.
    static func plainly(_ text: String?) -> String {
        (text ?? "").replacingOccurrences(of: " · ", with: ", ")
    }

    private static func said(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// "Monday 28 September" -- `dayLabel` in the words a person says. The
    /// locale is the reader's, as everywhere else here.
    static func spokenDayLabel(_ key: String, locale: Locale = .current) -> String {
        guard let weekday = text(key, locale: locale, style: .fullWeekday),
              let month = text(key, locale: locale, style: .fullMonth),
              let day = parts(key)?.day else { return key }
        return "\(weekday) \(day) \(month)"
    }

    /// "28 September to 4 October" -- the en dash in `rangeText` is a range
    /// sighted and a dash aloud.
    static func spokenRange(from: String, to: String, locale: Locale = .current) -> String {
        guard let left = parts(from), let right = parts(to),
              let leftMonth = text(from, locale: locale, style: .fullMonth),
              let rightMonth = text(to, locale: locale, style: .fullMonth)
        else { return rangeText(from: from, to: to, locale: locale) }
        if from == to { return "\(left.day) \(leftMonth)" }
        if left.year == right.year, left.month == right.month {
            return "\(left.day) to \(right.day) \(rightMonth)"
        }
        return "\(left.day) \(leftMonth) to \(right.day) \(rightMonth)"
    }

    /// "L" and "R" are a column heading, not a word.
    private static func sideWord(_ label: String) -> String {
        switch label {
        case "L": return SetSide.left.spokenLabel
        case "R": return SetSide.right.spokenLabel
        default: return label.lowercased()
        }
    }

    // MARK: - Keys

    /// The join key: name and equipment, `ExerciseKey`'s own spelling -- the
    /// identity the exercise dictionary, the per-side preference and the
    /// progression chart all already use.
    static func matchKey(name: String, equipment: String) -> String {
        ExerciseKey.make(name: name, equipment: equipment)
    }

    private static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: - Dates

    /// "Mon 13 Oct". A week can cross a month, and a bare "Mon 13" above a
    /// "Sun 5" says nothing about which. Coach's label, unchanged.
    static func dayLabel(_ key: String, locale: Locale = .current) -> String {
        guard let weekday = text(key, locale: locale, style: .weekday) else { return key }
        return "\(weekday) \(dayMonth(key, locale: locale))"
    }

    /// "13 Oct". Written day-then-month by hand rather than through a locale's
    /// own ordering, because "12–18 Oct" has to read as a range and a US
    /// ordering would put the month in the middle of it. LIFT web and Coach
    /// both do the same.
    static func dayMonth(_ key: String, locale: Locale = .current) -> String {
        guard let month = text(key, locale: locale, style: .month),
              let day = parts(key)?.day else { return key }
        return "\(day) \(month)"
    }

    /// "12–18 Oct", "28 Sep–4 Oct", "12 Oct" for a single day.
    static func rangeText(from: String, to: String, locale: Locale = .current) -> String {
        if from == to { return dayMonth(from, locale: locale) }
        if let left = parts(from), let right = parts(to),
           left.year == right.year, left.month == right.month {
            return "\(left.day)–\(dayMonth(to, locale: locale))"
        }
        return "\(dayMonth(from, locale: locale))–\(dayMonth(to, locale: locale))"
    }

    private enum DateStyle { case weekday, month, fullWeekday, fullMonth }

    /// Formatted in the reader's own locale, because that is what LIFT web's
    /// `toLocaleDateString(undefined, ...)` does and what `RoadFoodRanking`
    /// already decided for this app. Noon UTC with the style's time zone
    /// pinned to match: a day key is a calendar day, not an instant.
    private static func text(_ key: String, locale: Locale, style: DateStyle) -> String? {
        guard let date = noonUTC(key) else { return nil }
        var format = Date.FormatStyle(date: .omitted, time: .omitted)
        switch style {
        case .weekday: format = format.weekday(.abbreviated)
        case .month: format = format.month(.abbreviated)
        case .fullWeekday: format = format.weekday(.wide)
        case .fullMonth: format = format.month(.wide)
        }
        format = format.locale(locale)
        format.timeZone = utc
        return date.formatted(format)
    }

    /// Calendar's weekday for a key, 1 Sunday to 7 Saturday. Read off the key's
    /// own components in UTC, so a day key is a calendar day everywhere and a
    /// week does not start on a different day for someone in Auckland.
    private static func weekdayIndex(_ key: String) -> Int? {
        guard let date = noonUTC(key) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.component(.weekday, from: date)
    }

    /// Whole days, through `Calendar` -- never `now - days * 86400`, which
    /// repeats a day across a DST fall-back.
    private static func shift(_ key: String, by days: Int) -> String {
        guard days != 0, let date = noonUTC(key) else { return key }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        guard let moved = calendar.date(byAdding: .day, value: days, to: date) else { return key }
        let moving = calendar.dateComponents([.year, .month, .day], from: moved)
        guard let year = moving.year, let month = moving.month, let day = moving.day
        else { return key }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static let utc = TimeZone(identifier: "UTC")!

    private static func noonUTC(_ key: String) -> Date? {
        guard let parts = parts(key) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: parts.year, month: parts.month,
                                                  day: parts.day, hour: 12))
    }

    private static func parts(_ key: String) -> (year: Int, month: Int, day: Int)? {
        let pieces = key.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, let year = Int(pieces[0]), let month = Int(pieces[1]),
              let day = Int(pieces[2]), (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return (year, month, day)
    }

    // MARK: - Every sentence, flattened

    /// Every sentence this card can produce, in the order it is read. The
    /// line-discipline tests run over this rather than over a view, so a
    /// string that grades a week fails a test the day it is written rather
    /// than the day someone notices it on a screen.
    static func lines(_ result: Result?) -> [String] {
        guard let result else { return [] }
        var out = [result.head]
        for day in result.days {
            out.append(day.text)
            for exercise in day.exercises {
                out.append(exercise.title)
                if let side = exercise.sideLine { out.append(side) }
                if let count = exercise.countLine { out.append(count) }
                if let asked = exercise.asked { out.append(asked.label + " " + asked.text) }
                if let logged = exercise.logged { out.append(logged.label + " " + logged.text) }
                // Under the pair, as it sits on screen: the substitution line
                // says what the two rows above it are, and reads as nonsense
                // above them.
                if let substitution = exercise.substitution { out.append(substitution) }
            }
            if !day.alsoLogged.isEmpty {
                out.append("Also logged")
                out.append(contentsOf: day.alsoLogged.map(\.text))
            }
        }
        out.append(result.footer)
        return out
    }

    /// Every sentence a screen reader can be handed, in the order it is read
    /// -- `lines`, said.
    ///
    /// Its own list rather than a widening of `lines`, which the
    /// line-discipline tests already walk against the strings they pin. This
    /// exists so they walk the announced sentences too: a label is a sentence
    /// you read, and nothing here grades you in either form.
    static func spokenLines(_ result: Result?) -> [String] {
        guard let result else { return [] }
        var out = [result.spokenHead]
        for day in result.days {
            out.append(day.spoken)
            out.append(contentsOf: day.exercises.map(\.spoken))
            if !day.alsoLogged.isEmpty {
                out.append("Also logged")
                out.append(contentsOf: day.alsoLogged.map(\.spoken))
            }
        }
        out.append(result.footer)
        return out
    }
}
