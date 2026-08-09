import SwiftUI
import SwiftData

/// Search over the bundled exercises.db. Everything here is local — no network,
/// so results are effectively instant and work offline by construction.
struct ExercisePickerView: View {
    @Environment(\.dismiss) private var dismiss

    let onSelect: (ExerciseRecord) -> Void

    /// Everything the user has ever logged, newest session first. This is the
    /// signal that static ranking cannot provide: no amount of ORDER BY tuning
    /// on the reference data can tell whether "bench" means bench press or
    /// bench dips, but their own history can.
    @Query(sort: \WorkoutDay.date, order: .reverse)
    private var days: [WorkoutDay]

    @State private var query = ""
    @State private var results: [ExerciseRecord] = []
    @State private var loadFailed = false

    /// Reference IDs in most-recently-used order, de-duplicated.
    private var recentRefIDs: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for day in days {
            for exercise in day.orderedExercises where !seen.contains(exercise.exerciseRefID) {
                seen.insert(exercise.exerciseRefID)
                ordered.append(exercise.exerciseRefID)
            }
        }
        return ordered
    }

    var body: some View {
        NavigationStack {
            Group {
                if loadFailed {
                    ContentUnavailableView(
                        "Exercise data unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("exercises.db is missing from the app bundle.")
                    )
                } else if results.isEmpty && !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List {
                        ForEach(results) { record in
                            Button {
                                onSelect(record)
                                dismiss()
                            } label: {
                                row(record)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search 873 exercises")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            // Re-runs whenever query changes; the sleep debounces keystrokes,
            // and SwiftUI cancels the previous task automatically.
            .task(id: query) {
                await search()
            }
        }
    }

    private func row(_ record: ExerciseRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(record.name)
                    .font(.body)
                if recentRefIDs.contains(record.id) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
            }
            HStack(spacing: 6) {
                if let muscle = record.primaryMuscle {
                    Text(muscle.capitalized)
                }
                if let equipment = record.equipment, !equipment.isEmpty {
                    Text("·")
                    Text(equipment.capitalized)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func search() async {
        if !query.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
        }

        do {
            let found = query.isEmpty
                ? try await ReferenceDatabase.shared.allExercises(limit: 200)
                : try await ReferenceDatabase.shared.searchExercises(query)
            guard !Task.isCancelled else { return }
            results = rankByHistory(found)
            loadFailed = false
        } catch {
            results = []
            loadFailed = true
        }
    }

    /// Stable partition: previously-logged exercises float to the top in
    /// recency order, everything else keeps the database's ordering. Someone
    /// who benches every week gets their bench press first; someone who does
    /// dips gets dips. Neither ordering is "correct" in the abstract.
    private func rankByHistory(_ records: [ExerciseRecord]) -> [ExerciseRecord] {
        let ranks = Dictionary(uniqueKeysWithValues: recentRefIDs.enumerated().map { ($1, $0) })
        guard !ranks.isEmpty else { return records }

        var used: [(rank: Int, record: ExerciseRecord)] = []
        var unused: [ExerciseRecord] = []

        for record in records {
            if let rank = ranks[record.id] {
                used.append((rank, record))
            } else {
                unused.append(record)
            }
        }

        return used.sorted { $0.rank < $1.rank }.map(\.record) + unused
    }
}
