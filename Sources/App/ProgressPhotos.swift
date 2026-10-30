import SwiftUI
import PhotosUI
import UIKit
import LiftCore

/// Progress photos: kept as files in LIFT's own container, never in the
/// SwiftData store, never in a backup file, never in an iCloud or computer
/// backup of the phone, never sent with a coach link.
///
/// Files rather than rows because a photo is megabytes and the store is
/// copied whole into every backup; a backup that quietly grew by a gigabyte of
/// pictures is a backup nobody can email to a new phone. The cost is said in
/// the screen's own words: a photo stays on this phone.
///
/// Picked with `PhotosPicker`, which runs outside the app and needs no
/// photo-library permission: LIFT only ever sees the one picture chosen.
struct ProgressPhotoStore {
    let directory: URL

    static let shared = ProgressPhotoStore(directory: URL.applicationSupportDirectory
        .appendingPathComponent("ProgressPhotos", isDirectory: true))

    struct Photo: Identifiable, Equatable {
        let url: URL
        let dayKey: String
        var id: String { url.lastPathComponent }
        var date: Date { DayKey.date(from: dayKey) ?? .distantPast }
    }

    /// Oldest first. A file whose name does not start with a day is not one
    /// of these and is left alone.
    func photos() -> [Photo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> Photo? in
            guard name.hasSuffix(".jpg"), name.count > 10 else { return nil }
            let key = String(name.prefix(10))
            guard DayKey.date(from: key) != nil else { return nil }
            return Photo(url: directory.appendingPathComponent(name), dayKey: key)
        }
        .sorted { $0.dayKey != $1.dayKey ? $0.dayKey < $1.dayKey : $0.id < $1.id }
    }

    /// Re-encoded as a JPEG no longer than 2048 px on its long side, which is
    /// plenty to compare two photos and a fraction of a camera original. The
    /// re-encode also leaves the original's location metadata behind.
    @discardableResult
    func save(_ data: Data, on day: Date = .now) throws -> Photo {
        guard let image = UIImage(data: data), let jpeg = Self.scaled(image).jpegData(compressionQuality: 0.8)
        else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try excludeFromDeviceBackup()
        let key = DayKey.make(from: day)
        let url = directory.appendingPathComponent("\(key)_\(UUID().uuidString).jpg")
        try jpeg.write(to: url, options: [.atomic, .completeFileProtection])
        return Photo(url: url, dayKey: key)
    }

    /// Application Support is in iCloud and computer backups by default, and
    /// app-privacy.md says progress photos are never uploaded. Marking the
    /// folder keeps everything in it out of both. Set on every save rather
    /// than once, so a folder an earlier build made is covered too.
    func excludeFromDeviceBackup() throws {
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }

    func delete(_ photo: Photo) {
        try? FileManager.default.removeItem(at: photo.url)
    }

    static func scaled(_ image: UIImage, longest: CGFloat = 2048) -> UIImage {
        let size = image.size
        let scale = min(1, longest / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// Home → Body weight → Photos.
struct ProgressPhotosView: View {
    @Environment(\.dismiss) private var dismiss
    var store = ProgressPhotoStore.shared

    @State private var photos: [ProgressPhotoStore.Photo] = []
    @State private var picked: PhotosPickerItem?
    @State private var comparing: (ProgressPhotoStore.Photo, ProgressPhotoStore.Photo)?
    @State private var confirmingDelete: ProgressPhotoStore.Photo?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                    if photos.count >= 2, let first = photos.first, let last = photos.last {
                        Button("Compare \(PlanDayText.short(first.date)) with \(PlanDayText.short(last.date))") {
                            comparing = (first, last)
                        }
                        .foregroundStyle(Theme.accentText)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                        ForEach(photos) { photo in
                            thumbnail(photo)
                        }
                    }
                    Text("Photos stay on this phone, in LIFT's own storage. They are not in backup files and never go to a coach. Deleting LIFT deletes them.")
                        .font(Theme.detail)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Progress photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    PhotosPicker(selection: $picked, matching: .images) {
                        Label("Add photo", systemImage: "plus")
                    }
                }
            }
            .task { photos = store.photos() }
            .onChange(of: picked) { _, item in
                guard let item else { return }
                Task {
                    defer { picked = nil }
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          (try? store.save(data)) != nil else { failed = true; return }
                    photos = store.photos()
                }
            }
            .sheet(isPresented: Binding(get: { comparing != nil }, set: { if !$0 { comparing = nil } })) {
                if let comparing { PhotoCompareView(before: comparing.0, after: comparing.1, all: photos) }
            }
            .alert("That photo couldn't be added.", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            }
            .confirmationDialog("Delete this photo?", isPresented: Binding(
                get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let photo = confirmingDelete { store.delete(photo); photos = store.photos() }
                }
            } message: {
                Text("It is only on this phone, so this can't be undone.")
            }
        }
    }

    private func thumbnail(_ photo: ProgressPhotoStore.Photo) -> some View {
        VStack(spacing: 4) {
            Color.clear
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay {
                    if let image = UIImage(contentsOfFile: photo.url.path) {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(PlanDayText.short(photo.date))
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .contextMenu {
            Button("Delete", role: .destructive) { confirmingDelete = photo }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Photo from \(PlanDayText.short(photo.date))")
    }
}

/// Two photos one over the other, with a handle to slide between them.
struct PhotoCompareView: View {
    @Environment(\.dismiss) private var dismiss
    @State var before: ProgressPhotoStore.Photo
    @State var after: ProgressPhotoStore.Photo
    let all: [ProgressPhotoStore.Photo]
    @State private var split: CGFloat = 0.5

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        image(after).frame(width: geometry.size.width, height: geometry.size.height)
                        image(before)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: geometry.size.width * split)
                            }
                        Rectangle()
                            .fill(.white)
                            .frame(width: 2)
                            .offset(x: geometry.size.width * split - 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        split = min(1, max(0, value.location.x / max(geometry.size.width, 1)))
                    })
                }
                .aspectRatio(3 / 4, contentMode: .fit)
                .accessibilityElement()
                .accessibilityLabel("Before and after")
                .accessibilityValue("\(Int(split * 100)) percent before")
                .accessibilityAdjustableAction { direction in
                    split = min(1, max(0, split + (direction == .increment ? 0.1 : -0.1)))
                }

                HStack {
                    picker("Before", selection: $before)
                    Spacer()
                    picker("After", selection: $after)
                }
            }
            .padding(16)
            .background(Theme.background)
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func image(_ photo: ProgressPhotoStore.Photo) -> some View {
        Group {
            if let image = UIImage(contentsOfFile: photo.url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Theme.hairline
            }
        }
        .clipped()
    }

    private func picker(_ title: String, selection: Binding<ProgressPhotoStore.Photo>) -> some View {
        Menu("\(title): \(PlanDayText.short(selection.wrappedValue.date))") {
            ForEach(all) { photo in
                Button(PlanDayText.short(photo.date)) { selection.wrappedValue = photo }
            }
        }
        .foregroundStyle(Theme.accentText)
    }
}

/// "26 Oct 2026", the reader's way.
enum PlanDayText {
    static func short(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
