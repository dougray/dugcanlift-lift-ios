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
        /// How many times LIFT has opened this recipe's review without it
        /// ending in Save or Cancel. The queue's count, not part of what the
        /// recipe is: nil from the share extension and in files written
        /// before the count existed, and left out of `==`.
        var opened: Int? = nil

        static func == (a: Item, b: Item) -> Bool {
            a.block == b.block && a.pageURL == b.pageURL
        }
    }

    static let appGroup = "group.com.dugcanlift.lift"
    static let folder = "PendingRecipeImports"
    /// The link queue's bound: a stuck queue cannot grow forever.
    static let limit = 20
    /// Opens without a Save or Cancel before a recipe is given up: a page
    /// whose review crashes LIFT must not open on every launch for ever.
    static let mostOpens = 3

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

    /// Everything waiting for review, oldest first. Nothing is deleted for
    /// being read: a recipe stays until its review ends (`remove`), so iOS
    /// ending LIFT mid-review loses nothing. A file that no longer decodes,
    /// or a recipe opened `mostOpens` times without finishing, is deleted
    /// here, so neither can repeat for ever.
    func forReview() -> [Item] {
        var items: [Item] = []
        for url in sequenceFiles() {
            guard let item = Self.decode(url), (item.opened ?? 0) < Self.mostOpens else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            items.append(item)
        }
        return items
    }

    /// A review of `item` has opened. Counted in its own file, so the count
    /// survives LIFT being ended.
    func markOpened(_ item: Item) {
        for file in queuedFiles() where file.item == item {
            var counted = file.item
            counted.opened = (counted.opened ?? 0) + 1
            try? JSONEncoder().encode(counted).write(to: file.url, options: .atomic)
        }
    }

    /// The review of `item` ended in Save or Cancel: it is done with.
    func remove(_ item: Item) {
        for file in queuedFiles() where file.item == item {
            try? FileManager.default.removeItem(at: file.url)
        }
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
