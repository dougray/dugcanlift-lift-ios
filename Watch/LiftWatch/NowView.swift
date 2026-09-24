import LiftKit
import SwiftUI
import LiftSync

/// The guided session's first page: what to lift, which set it is, what the
/// prescription says in digits big enough to read mid-set, what was actually
/// done last time, and the current heart rate.
///
/// Shown only while a plan is being trained. A workout started with no plan
/// never reaches this screen, and `WorkoutView` does not put it in the tab
/// order at all — free entry is exactly the three pages it always was.
struct NowView: View {
    @EnvironmentObject private var session: WorkoutSessionModel

    var body: some View {
        ScrollView {
            if let guided = session.guided, let exercise = guided.currentExercise {
                training(guided, exercise)
            } else {
                finished
            }
        }
    }

    @ViewBuilder
    private func training(_ guided: GuidedSession, _ exercise: PlanExercise) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(guided.plan.name.uppercased())
                    .font(.caption2)
                    .foregroundStyle(DclTheme.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(guided.positionText)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }

            Text(exercise.displayName)
                .font(.headline)
                .lineLimit(2)

            // The prescription, in the size the spec draws it. A blank field
            // is never a zero here: "5 reps" is a set with no weight
            // prescribed, and "—" is a set that prescribes nothing at all.
            // With a side in play it reads "30 x 8 · L", and the position
            // above it "3/6 · L" — six because an each-side exercise's three
            // prescribed rows are six sets to perform.
            Text(guided.currentPrescription?
                    .headline(unit: session.unit, side: guided.currentSide) ?? "—")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            if let rpe = guided.currentPrescription?.rpe {
                Text("RPE \(PlanFormat.rpe(rpe))")
                    .font(.caption2)
                    .foregroundStyle(DclTheme.muted)
            }

            if let last = exercise.lastPerformed?.summary(unit: session.unit) {
                Text("last: \(last)")
                    .font(.caption2)
                    .foregroundStyle(DclTheme.muted)
            }

            if let note = exercise.note, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(DclTheme.accent2)
                    .lineLimit(2)
            }

            HeartRateLabel()

            if let exerciseID = session.guidedExerciseID {
                NavigationLink("Log Set") {
                    LogSetView(exerciseID: exerciseID)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private var finished: some View {
        VStack(spacing: 8) {
            Text("Plan done")
                .font(.headline)
            if let guided = session.guided {
                Text("\(guided.completedSetCount) of \(guided.plan.totalSetCount) sets")
                    .font(.caption2)
                    .foregroundStyle(DclTheme.muted)
            }
            Text("Finish on the Summary page, or keep lifting off plan.")
                .font(.caption2)
                .foregroundStyle(DclTheme.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 4)
    }
}

/// Current beats per minute, or nothing at all.
///
/// Deliberately shows no number until a sample has actually landed: a watch
/// simulator produces none, and a permission can be refused, and "0" or "--"
/// pretending to be a reading is worse than a line that is not there.
struct HeartRateLabel: View {
    @EnvironmentObject private var heartRate: LiftingSessionRecorder

    var body: some View {
        if let bpm = heartRate.currentBpm {
            Label("\(Int(bpm.rounded())) bpm", systemImage: "heart.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DclTheme.accent)
                .monospacedDigit()
        }
    }
}
