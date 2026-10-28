import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import LiftCore

/// Settings → Your data: training history in from another app, and out as a
/// spreadsheet. Both are files the person handles; nothing is sent anywhere.
struct WorkoutCSVSection: View {
    @State private var importing = false
    @State private var reading: PendingImport?
    @State private var exportFile: CSVExportFile?
    @State private var message: String?
    @Environment(\.modelContext) private var context

    var body: some View {
        Group {
            Button("Import from Strong, Hevy or FitNotes") { importing = true }
            Button("Export training as a spreadsheet (CSV)") { exportFile = writeExport() }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.commaSeparatedText, .plainText, .text, .data]) { result in
            guard let url = try? result.get() else { message = "Could not read that file."; return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                message = "Could not read that file."
                return
            }
            do {
                reading = PendingImport(reading: try WorkoutCSV.read(text))
            } catch {
                message = "That doesn't look like an export from Strong, Hevy or FitNotes."
            }
        }
        .sheet(item: $reading) { pending in
            WorkoutCSVImportSheet(pending: pending) { outcome in
                message = Self.summary(outcome)
            }
        }
        .sheet(item: $exportFile) { file in
            ShareSheet(items: [file.url])
        }
    }

    private func writeExport() -> CSVExportFile? {
        let text = WorkoutCSV.export(WorkoutCSV.exportRows(from: context))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lift-training-\(BackupStore.todayKey()).csv")
        do { try Data(text.utf8).write(to: url, options: .atomic) } catch {
            message = "Could not write the file."
            return nil
        }
        return CSVExportFile(url: url)
    }

    static func summary(_ outcome: WorkoutCSV.Outcome) -> String {
        var parts: [String] = []
        parts.append(outcome.daysAdded == 1 ? "Added 1 day" : "Added \(outcome.daysAdded) days")
        parts[0] += outcome.setsAdded == 1 ? " (1 set)." : " (\(outcome.setsAdded) sets)."
        if outcome.daysSkipped > 0 {
            parts.append(outcome.daysSkipped == 1
                         ? "1 day you already had training on was left as it was."
                         : "\(outcome.daysSkipped) days you already had training on were left as they were.")
        }
        return parts.joined(separator: " ")
    }
}

struct PendingImport: Identifiable {
    let id = UUID()
    let reading: WorkoutCSV.Reading
}

struct CSVExportFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// What the file holds, the one question when the file can't answer it, and
/// Import.
struct WorkoutCSVImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let pending: PendingImport
    let onDone: (WorkoutCSV.Outcome) -> Void

    @State private var unit: WeightUnit?

    private var workouts: [WorkoutCSV.ImportedWorkout]? {
        guard !pending.reading.needsUnit || unit != nil else { return nil }
        return pending.reading.parse(unit)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("From \(pending.reading.source.rawValue)")
                        .font(.headline)
                    if let workouts {
                        Text(WorkoutCSVImportSheet.describe(workouts))
                    }
                } footer: {
                    Text("Days you already have training on in LIFT are left exactly as they are, so importing the same file twice adds nothing the second time.")
                }
                if pending.reading.needsUnit {
                    Section {
                        Picker("Weights in this file are in", selection: $unit) {
                            Text("Choose").tag(WeightUnit?.none)
                            Text("Pounds (lb)").tag(WeightUnit?.some(.pounds))
                            Text("Kilograms (kg)").tag(WeightUnit?.some(.kilograms))
                        }
                    } footer: {
                        Text("This Strong file doesn't say. It is whichever unit Strong was showing when you exported it.")
                    }
                }
            }
            .navigationTitle("Import training")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        guard let workouts else { return }
                        onDone(WorkoutCSV.apply(workouts, source: pending.reading.source, in: context))
                        dismiss()
                    }
                    .disabled(workouts?.isEmpty ?? true)
                }
            }
        }
    }

    static func describe(_ workouts: [WorkoutCSV.ImportedWorkout]) -> String {
        guard let first = workouts.first?.date, let last = workouts.last?.date else {
            return "No sets found in this file."
        }
        let sets = workouts.reduce(0) { $0 + $1.exercises.reduce(0) { $0 + $1.sets.count } }
        let span = first.formatted(date: .abbreviated, time: .omitted) + " to "
            + last.formatted(date: .abbreviated, time: .omitted)
        return "\(workouts.count == 1 ? "1 workout" : "\(workouts.count) workouts"), "
            + "\(sets == 1 ? "1 set" : "\(sets) sets"), \(span)."
    }
}

/// The system share sheet for a file (Save to Files, AirDrop, Mail…).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
