import Foundation

/// A lift's identity wherever sets are grouped or charted: **name, equipment
/// and side**.
///
/// Equipment joined the key because a cable pulldown and a machine pulldown
/// are not the same lift, and charting them together produced one zig-zagging
/// line that was the average of two honest trends. Side joins it for exactly
/// the same reason. A two-sided lift has `side == nil` and is completely
/// unaffected: one key, one series, the same numbers as before.
struct LiftKey: Hashable, Sendable {
    var name: String
    var equipment: String?
    var side: SetSide?

    /// The lift without its side — what an exercise picker, a preference and a
    /// chart title all name.
    var exerciseKey: String { ExerciseKey.make(name: name, equipment: equipment) }

    static func make(exercise: ExerciseEntry, set: SetEntry) -> LiftKey {
        LiftKey(name: exercise.name, equipment: exercise.equipment, side: set.side)
    }
}

/// One day's best estimated 1RM for one side of one lift.
///
/// A day, not a set: two sides on the same date are two points on two lines,
/// and three sets of the same side on one date are one point. "Sessions" in
/// the imbalance rule below means days, which is the unit a lifter counts in.
struct LiftSessionPoint: Hashable, Sendable {
    var dayKey: String
    var date: Date
    var estimatedOneRepMaxKg: Double
}

/// The L and R lines for one lift, or the single line a two-sided lift has.
struct LiftSeries: Identifiable, Sendable {
    var side: SetSide?
    var points: [LiftSessionPoint]

    var id: String { side?.rawValue ?? "both" }

    /// The best day in the window — a caption under the chart, and nothing
    /// more. **The imbalance figure does not use this**: it averages each
    /// side's last three sessions, because a peak rewards one good day
    /// forever. See `LiftProgression.imbalance`.
    var bestOneRepMaxKg: Double? { points.map(\.estimatedOneRepMaxKg).max() }

    /// The mean of the last three sessions — the number the imbalance figure
    /// is actually computed from, so a view can show its working.
    var recentMeanOneRepMaxKg: Double? {
        let recent = points.suffix(LiftProgression.minimumSessionsPerSide)
            .map(\.estimatedOneRepMaxKg)
        guard !recent.isEmpty else { return nil }
        return recent.reduce(0, +) / Double(recent.count)
    }

    var sessionCount: Int { points.count }
}

/// How far apart the two sides are, and which way that is moving.
///
/// **Tracked and shown, never targeted.** There is no threshold in this type,
/// no "high", no colour, and nothing that decides a number is bad — the same
/// discipline saturated fat, sugar and sodium are held to. A 10% gap is
/// ordinary in most people, this app is not qualified to say what one person's
/// means, and a trainer is.
struct LiftImbalance: Sendable {
    /// The side whose recent mean is higher, or nil for a dead heat.
    var strongerSide: SetSide?
    /// `(strong − weak) / strong`, in percentage points. 0 for a matched pair.
    var percent: Double
    /// The same figure over the window's *first* three sessions, when there
    /// were enough sessions to compute one. This is what `trend` compares
    /// against, and it is carried so a view can say "was 3.1%".
    var previousPercent: Double?
    var trend: Trend

    /// Whether the gap is getting bigger or smaller across the window.
    ///
    /// `.notEnoughData` rather than a guess: with exactly three sessions the
    /// first three and the last three are the same sessions, so "steady"
    /// would be arithmetic rather than an observation.
    enum Trend: Sendable, Equatable { case widening, closing, steady, notEnoughData }

    /// "4.2%", and "5%" for a round one — one decimal, which is as much
    /// precision as an Epley estimate off a rep-range lift can honestly
    /// carry. Coach web rounds to a tenth and JavaScript drops a trailing
    /// zero, so a plain `%.1f` would print "5.0%" where every other app
    /// prints "5%".
    var percentText: String {
        let rounded = (percent * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? "\(Int(rounded))%" : String(format: "%.1f%%", rounded)
    }

    /// The word after "gap " in the detail line: Coach web's own values
    /// (`widening` / `closing` / `steady`), not a rephrasing.
    var trendText: String? {
        switch trend {
        case .widening:       "widening"
        case .closing:        "closing"
        case .steady:         "steady"
        case .notEnoughData:  nil
        }
    }
}

/// What the per-limb card prints: a short headline and a quieter line saying
/// what it was measured over, or what is still missing.
///
/// A port of Coach web's `imbalanceLines` (`coach/sides.js`), word for word —
/// Coach iOS carries the same port — so a lifter and their coach read the same
/// sentence about the same log on every platform:
///
/// - "Right ahead by 5%" / "Sides level", over "Mean estimated 1RM of the
///   last 3 sessions each · gap closing" (or "gap widening", "gap steady",
///   and no clause at all when the trend cannot be judged);
/// - below the threshold, "—" over "Needs 3 sessions a side · 2 left, 2
///   right so far", so "not enough yet" says what is missing.
///
/// Stated and nothing more: no threshold, no colour, no advice.
struct ImbalanceLines: Equatable, Sendable {
    var headline: String
    var detail: String

    static func make(left: [LiftSessionPoint], right: [LiftSessionPoint]) -> ImbalanceLines {
        let sessions = LiftProgression.minimumSessionsPerSide
        guard let imbalance = LiftProgression.imbalance(left: left, right: right) else {
            return ImbalanceLines(
                headline: "—",
                detail: "Needs \(sessions) sessions a side · "
                    + "\(LiftProgression.recordedSessionCount(left)) left, "
                    + "\(LiftProgression.recordedSessionCount(right)) right so far")
        }
        let headline = imbalance.strongerSide.map {
            "\($0.displayName) ahead by \(imbalance.percentText)"
        } ?? "Sides level"
        let basis = "Mean estimated 1RM of the last \(sessions) sessions each"
        return ImbalanceLines(headline: headline,
                              detail: imbalance.trendText.map { "\(basis) · gap \($0)" } ?? basis)
    }

    /// Over the series the chart already built.
    static func make(in series: [LiftSeries]) -> ImbalanceLines {
        make(left: series.first { $0.side == .left }?.points ?? [],
             right: series.first { $0.side == .right }?.points ?? [])
    }
}

/// Grouping and imbalance for the exercise progression chart.
///
/// A plain enum of static functions with no view and no SwiftUI import, for
/// the reason `MacroFields` and `LinkImportMacros` are value types in Cook: a
/// rule living in a view's `@State` cannot be tested, and this one decides
/// what number a lifter reads about their own body.
enum LiftProgression {

    /// How many sessions each side needs before an imbalance figure is shown
    /// at all, and how many are averaged to produce it. A floor on both sides
    /// independently — six left sessions and two right ones gets no figure,
    /// because the right-hand number would be one bad day away from
    /// meaningless.
    static let minimumSessionsPerSide = 3

    /// Sessions a side needs before a trend is claimed. With exactly three,
    /// the first three and the last three are the same sessions and "steady"
    /// would be arithmetic rather than an observation.
    static let minimumSessionsForTrend = 4

    /// A gap that moves less than this many percentage points across the
    /// window is "holding steady" rather than a direction. Half a point is
    /// noise in an estimate built out of an estimate.
    static let steadyBandPercentagePoints = 0.5

    // MARK: - Grouping

    /// Every series for one lift, over the days given.
    ///
    /// Warmups and sets with no computable estimate are excluded by
    /// `estimatedOneRepMaxKg` itself, which is where that rule already lived.
    /// The returned array is `[nil]` for a purely two-sided lift, `[.left,
    /// .right]` for one logged per side, and can be all three for a lift
    /// whose owner turned the preference on halfway through — those really are
    /// three different things and merging them would invent a history.
    static func series(for exerciseKey: String, in days: [WorkoutDay]) -> [LiftSeries] {
        var buckets: [SetSide?: [String: LiftSessionPoint]] = [:]

        for day in days {
            for exercise in day.exercises where
                ExerciseKey.make(name: exercise.name, equipment: exercise.equipment) == exerciseKey {
                for set in exercise.sets {
                    guard let estimate = set.estimatedOneRepMaxKg else { continue }
                    let existing = buckets[set.side]?[day.dayKey]
                    if existing == nil || existing!.estimatedOneRepMaxKg < estimate {
                        buckets[set.side, default: [:]][day.dayKey] = LiftSessionPoint(
                            dayKey: day.dayKey, date: day.date, estimatedOneRepMaxKg: estimate)
                    }
                }
            }
        }

        // Stable order: both, then left, then right, so a legend never
        // reshuffles between renders.
        let order: [SetSide?] = [nil, .left, .right]
        return order.compactMap { side in
            guard let points = buckets[side], !points.isEmpty else { return nil }
            return LiftSeries(side: side,
                              points: points.values.sorted { $0.date < $1.date })
        }
    }

    /// The same grouping over the whole log, for anything that needs every
    /// lift at once. Keyed by `LiftKey`, so L and R are two entries and a
    /// two-sided lift is one — a key type that cannot merge them by
    /// construction.
    static func allSeries(in days: [WorkoutDay]) -> [LiftKey: [LiftSessionPoint]] {
        var buckets: [LiftKey: [String: LiftSessionPoint]] = [:]
        for day in days {
            for exercise in day.exercises {
                for set in exercise.sets {
                    guard let estimate = set.estimatedOneRepMaxKg else { continue }
                    let key = LiftKey.make(exercise: exercise, set: set)
                    let existing = buckets[key]?[day.dayKey]
                    if existing == nil || existing!.estimatedOneRepMaxKg < estimate {
                        buckets[key, default: [:]][day.dayKey] = LiftSessionPoint(
                            dayKey: day.dayKey, date: day.date, estimatedOneRepMaxKg: estimate)
                    }
                }
            }
        }
        return buckets.mapValues { $0.values.sorted { $0.date < $1.date } }
    }

    /// Days from the chart's own window, so the headline figure and the lines
    /// above it always describe the same stretch of training.
    static func days(_ days: [WorkoutDay], within weeks: Int,
                     endingAt end: Date = .now,
                     calendar: Calendar = .current) -> [WorkoutDay] {
        // Calendar arithmetic, never `now - n * 86400`: subtracting seconds
        // repeats a day across a DST fall-back.
        guard let start = calendar.date(byAdding: .weekOfYear, value: -weeks,
                                        to: calendar.startOfDay(for: end))
        else { return days }
        return days.filter { $0.date >= start && $0.date <= end }
    }

    // MARK: - Imbalance

    /// The gap between two sides, from each side's per-session estimated 1RM
    /// across the window the chart is already showing.
    ///
    /// **This is a cross-platform rule, not a local choice.** LIFT web's
    /// `lift/sides.js` is the reference and LIFT Android matches it, so the
    /// three apps print the same number from the same log:
    ///
    /// - A side's figure is the **mean of its last three sessions**, not its
    ///   best day and not its latest. A single best rewards one good day
    ///   forever; a latest value moves ten points when someone trains tired,
    ///   and gets read as a finding either way.
    /// - Shown only when **both** sides have three sessions in the window.
    /// - `trend` compares that against the mean of the **first three**, and
    ///   needs four sessions a side before it says anything at all.
    ///
    /// Nil is a real answer and the view says so in words ("needs three
    /// sessions a side") rather than showing a figure with a quiet caveat: a
    /// percentage on screen gets read and remembered whatever is printed next
    /// to it.
    static func imbalance(left: [LiftSessionPoint], right: [LiftSessionPoint]) -> LiftImbalance? {
        // Chronological, and only sessions that actually recorded a number —
        // `recorded()` in the reference.
        let l = values(left)
        let r = values(right)

        guard l.count >= minimumSessionsPerSide,
              r.count >= minimumSessionsPerSide,
              let percent = gap(mean(l.suffix(minimumSessionsPerSide)),
                                mean(r.suffix(minimumSessionsPerSide)))
        else { return nil }

        let nowLeft = mean(l.suffix(minimumSessionsPerSide))
        let nowRight = mean(r.suffix(minimumSessionsPerSide))
        let stronger: SetSide? = nowLeft == nowRight ? nil : (nowLeft > nowRight ? .left : .right)

        var previous: Double?
        var trend = LiftImbalance.Trend.notEnoughData
        if l.count >= minimumSessionsForTrend, r.count >= minimumSessionsForTrend,
           let before = gap(mean(l.prefix(minimumSessionsPerSide)),
                            mean(r.prefix(minimumSessionsPerSide))) {
            previous = before
            let moved = percent - before
            trend = moved > steadyBandPercentagePoints ? .widening
                  : moved < -steadyBandPercentagePoints ? .closing
                  : .steady
        }

        return LiftImbalance(strongerSide: stronger, percent: percent,
                             previousPercent: previous, trend: trend)
    }

    /// Convenience over the series the chart already built.
    static func imbalance(in series: [LiftSeries]) -> LiftImbalance? {
        let left = series.first { $0.side == .left }?.points ?? []
        let right = series.first { $0.side == .right }?.points ?? []
        return imbalance(left: left, right: right)
    }

    /// `(strong − weak) / strong` in percentage points, or nil when there is
    /// no strong side to divide by.
    static func gap(_ a: Double, _ b: Double) -> Double? {
        let strong = max(a, b), weak = min(a, b)
        guard strong > 0 else { return nil }
        return (strong - weak) / strong * 100
    }

    /// Chronological estimates, dropping any session that recorded nothing
    /// usable — a zero or a non-finite value is not a light day, it is an
    /// absence, and averaging it in would invent a gap.
    /// Sessions that recorded a usable estimate — what "2 left, 2 right so
    /// far" counts, and exactly what the threshold is measured against.
    static func recordedSessionCount(_ points: [LiftSessionPoint]) -> Int {
        values(points).count
    }

    private static func values(_ points: [LiftSessionPoint]) -> [Double] {
        points
            .sorted { $0.date < $1.date }
            .map(\.estimatedOneRepMaxKg)
            .filter { $0.isFinite && $0 > 0 }
    }

    private static func mean(_ values: some Collection<Double>) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}
