import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Save the log to a file, and read one back.
///
/// There is no account and nothing in the cloud, so a file the user keeps is the
/// only thing between them and a lost training history — and the only way a log
/// moves to a new phone or in from the web version. The format is documented in
/// the site repo at `coach/BACKUP-FORMAT.md`.
struct BackupSection: View {

    @Environment(\.modelContext) private var context

    @State private var exporting = false
    @State private var importing = false
    @State private var document: BackupDocument?
    @State private var message: String?

    var body: some View {
        Section("Your data") {
            Text("Everything you log stays on this device. There is no account to "
                 + "log back into, so a reinstall or a new device takes it all with "
                 + "it. A backup file is the only copy that survives.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Save a backup file") {
                do {
                    document = BackupDocument(data: try BackupStore.build(context: context))
                    exporting = true
                } catch {
                    message = "Could not build the backup."
                }
            }

            Button("Restore from a backup file") { importing = true }

            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .fileExporter(
            isPresented: $exporting,
            document: document,
            contentType: .json,
            defaultFilename: "lift-\(BackupStore.todayKey())"
        ) { result in
            message = (try? result.get()) != nil ? "Backup saved." : "Could not save the backup."
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.json, .plainText]
        ) { result in
            guard let url = try? result.get() else {
                message = "Could not read that file."
                return
            }
            // A file coming from Files or iCloud Drive is security-scoped.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url) else {
                message = "Could not read that file."
                return
            }
            let outcome = BackupStore.restore(context: context, from: data)
            message = {
                if !outcome.ok { return outcome.problem ?? "That file isn't a LIFT backup." }
                switch outcome.added {
                case 0: return "Restored. This device already had everything in that file."
                case 1: return "Restored. Added 1 entry this device didn't have."
                default: return "Restored. Added \(outcome.added) entries this device didn't have."
                }
            }()
        }
    }
}

/// Thin wrapper so `fileExporter` can hand the bytes to the document picker.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
