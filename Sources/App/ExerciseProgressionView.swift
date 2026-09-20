import Charts
import SwiftUI
import SwiftData
import LiftCore

/// Estimated 1RM over time for one lift — and, when it is logged a limb at a
/// time, one line per side with the gap between them stated underneath.
///
/// Every number on this screen comes from `LiftProgression`, which has no view
/// in it and is unit tested. Nothing here decides anything: the view asks for
/// the series and the imbalance and draws what it is given, so the rule about
/// what a lifter is told about their own body lives somewhere it can be
/// checked.
struct ExerciseProgressionView: View {
    let name: String
    let equipment: String?

    @AppStorage("weightUnit") private var unitRaw = WeightUnit.pounds.rawValue
    @State private var weeks = 8

    @Query(sort: \WorkoutDay.date) private var days: [WorkoutDay]

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .pounds }

    private var windowDays: [WorkoutDay] {
        LiftProgression.days(days, within: weeks)
    }

    private var series: [LiftSeries] {
        LiftProgression.series(
            for: ExerciseKey.make(name: name, equipment: equipment), in: windowDays)
    }

    /// The headline figure and the lines above it always describe the same
    /// stretch of training — the imbalance is computed from the series the
    /// chart drew, never from a window of its own.
    private var imbalance: LiftImbalance? { LiftProgression.imbalance(in: series) }

    private var hasSides: Bool { series.contains { $0.side != nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                Text(displayName)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)

                Picker("Window", selection: $weeks) {
                    Text("8 weeks").tag(8)
                    Text("6 months").tag(26)
                    Text("A year").tag(52)
                }
                .pickerStyle(.segmented)

                chartCard

                if hasSides { imbalanceCard }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
            .adaptivePageWidth()
        }
        .liftScreen()
    }

    private var displayName: String {
        guard let equipment, !equipment.isEmpty else { return name }
        return "\(name) (\(equipment.capitalized))"
    }

    @ViewBuilder
    private var chartCard: some View {
        LiftCard(title: "Estimated 1RM") {
            if series.isEmpty {
                Text("No working sets of this lift in the last \(weeks) weeks. A set needs a weight and reps before it can be estimated, and warmups are left out.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Chart {
                    ForEach(series) { line in
                        ForEach(line.points, id: \.dayKey) { point in
                            LineMark(
                                x: .value("Date", point.date),
                                y: .value(unit.abbreviation,
                                          unit.fromKilograms(point.estimatedOneRepMaxKg)),
                                series: .value("Side", label(for: line.side))
                            )
                            .foregroundStyle(by: .value("Side", label(for: line.side)))
                            PointMark(
                                x: .value("Date", point.date),
                                y: .value(unit.abbreviation,
                                          unit.fromKilograms(point.estimatedOneRepMaxKg))
                            )
                            .foregroundStyle(by: .value("Side", label(for: line.side)))
                        }
                    }
                }
                // Built from the series actually drawn, not from all three
                // possible ones: a fixed domain puts "Both" in the legend of a
                // lift that has no two-sided sets in the window. And Both gets
                // a colour of its own, because a lift whose owner turned the
                // toggle on halfway through really does draw all three lines
                // and two of them must not be the same red.
                .chartForegroundStyleScale(
                    domain: series.map { label(for: $0.side) },
                    range: series.map { colour(for: $0.side) })
                // One series or three, the legend only earns its space when
                // there is more than one line to tell apart.
                .chartLegend(series.count > 1 ? .visible : .hidden)
                .frame(height: 220)

                ForEach(series) { line in
                    Text("\(label(for: line.side)) · \(line.sessionCount) session\(line.sessionCount == 1 ? "" : "s")"
                         + (line.bestOneRepMaxKg.map { " · best \(weightText($0))" } ?? "")
                         + (line.sessionCount >= LiftProgression.minimumSessionsPerSide
                            ? (line.recentMeanOneRepMaxKg.map { " · last 3 average \(weightText($0))" } ?? "")
                            : ""))
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    /// **Tracked and shown, never targeted.** No threshold, no colour, no
    /// prompt to fix anything — the same discipline saturated fat, sugar and
    /// sodium are held to. A gap of a few per cent is ordinary, this app is
    /// not qualified to say what one person's means, and a trainer is. The
    /// card says that in words rather than leaving the number to be read as a
    /// verdict.
    @ViewBuilder
    private var imbalanceCard: some View {
        LiftCard(title: "Left and right") {
            if let imbalance {
                Text(headline(imbalance))
                    .font(Theme.figure)
                    .foregroundStyle(Theme.textPrimary)

                if let trendText = imbalance.trendText {
                    Text("The gap is \(trendText)"
                         + (imbalance.previousPercent.map {
                             " — it was \(String(format: "%.1f%%", $0)) over the first three sessions in this window."
                         } ?? " across these \(weeks) weeks."))
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text("A trend needs \(LiftProgression.minimumSessionsForTrend) sessions a side. With three, the first three and the last three are the same sessions.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                }

                Text("Estimated 1RM, averaged over each side's last \(LiftProgression.minimumSessionsPerSide) sessions. A difference between limbs is normal and this is here to be watched, not fixed to a number.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text("A figure needs at least \(LiftProgression.minimumSessionsPerSide) sessions on each side inside this window. Below that a single heavy day decides the answer, which is worse than no answer.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// "Left ahead by 4.2%", or "Even" for a dead heat — `strongerSide` is
    /// nil exactly then, and "ahead by 0.0%" would be a strange thing to read.
    private func headline(_ imbalance: LiftImbalance) -> String {
        guard let stronger = imbalance.strongerSide else { return "Even" }
        return "\(stronger.displayName) ahead by \(imbalance.percentText)"
    }

    private func label(for side: SetSide?) -> String {
        side?.displayName ?? "Both"
    }

    private func colour(for side: SetSide?) -> Color {
        switch side {
        case .left:  Theme.accent
        case .right: Theme.accentSecondary
        case nil:    Theme.textSecondary
        }
    }

    private func weightText(_ kg: Double) -> String {
        let value = unit.fromKilograms(kg)
        let text = value == value.rounded()
            ? String(Int(value)) : String(format: "%.1f", value)
        return "\(text) \(unit.abbreviation)"
    }
}
