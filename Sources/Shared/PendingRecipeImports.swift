import Foundation

/// Recipes the lifter confirmed in the share sheet, waiting in the App Group
/// container until LIFT next comes to the foreground and opens each for
/// review. The sibling of `PendingPlanLinks`, and queued for the same reason:
/// a share extension cannot open its app, and must not write SwiftData.
///
/// Files rather than `UserDefaults`, because a JSON-LD block can run to
/// hundreds of kilobytes; the link queue's small strings stay where they are.
/// Order comes from a sequence number in each file's name, never from a file
/// timestamp, so no required-reason API is read. Only the raw block and its
/// page's address cross: the app re-reads the block with the same parser.
/// Compiled into the app, its share extension and the widget; Foundation only.
struct PendingRecipeImports {

    struct Item: Codable, Equatable {
        /// The raw `application/ld+json` text that held the Recipe.
        var block: String
        /// The page's own address, as Safari reported it.
        var pageURL: String
    }

    static let appGroup = "group.com.dugcanlift.lift"
    static let folder = "PendingRecipeImports"
    /// The link queue's bound: a stuck queue cannot grow forever.
    static let limit = 20

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// Nil when the App Group entitlement is missing from the running build.
    static var shared: PendingRecipeImports? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else { return nil }
        return PendingRecipeImports(directory: container.appendingPathComponent(folder, isDirectory: true))
    }

    /// Queues an item. The same page shared twice is queued once, at the end.
    func add(_ item: Item) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = queuedFiles()
        let next = (existing.map(\.sequence).max() ?? 0) + 1
        for file in existing where file.item == item { try? fm.removeItem(at: file.url) }
        try JSONEncoder().encode(item).write(to: directory.appendingPathComponent(Self.fileName(next)),
                                             options: .atomic)
        for file in queuedFiles().dropLast(Self.limit) { try? fm.removeItem(at: file.url) }
    }

    /// Everything queued, oldest first, and empties the queue -- including any
    /// file that no longer decodes, so it cannot repeat forever.
    func takeAll() -> [Item] {
        let files = sequenceFiles()
        let items = files.compactMap { Self.decode($0) }
        for url in files { try? FileManager.default.removeItem(at: url) }
        return items
    }

    var pending: [Item] { queuedFiles().map(\.item) }

    // MARK: - Files

    private func sequenceFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { Self.sequence(of: $0) != nil }
            .sorted { Self.sequence(of: $0)! < Self.sequence(of: $1)! }
    }

    private func queuedFiles() -> [(url: URL, sequence: Int, item: Item)] {
        sequenceFiles().compactMap { url in
            guard let n = Self.sequence(of: url), let item = Self.decode(url) else { return nil }
            return (url, n, item)
        }
    }

    private static func decode(_ url: URL) -> Item? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Item.self, from: $0) }
    }

    static func fileName(_ sequence: Int) -> String { String(format: "%010d.json", sequence) }

    static func sequence(of url: URL) -> Int? {
        url.pathExtension == "json" ? Int(url.deletingPathExtension().lastPathComponent) : nil
    }
}
