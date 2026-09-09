import Foundation
import SwiftData

/// Extracted from `FoodView`'s original `recent` computed property so the
/// same "recently logged foods" logic can be reused outside a View — the
/// watch quick-log snapshot in particular (see `SyncEnvelope`).
enum RecentFoodsQuery {
    /// Most-recently-logged foods, deduplicated by display name (brand +
    /// name), newest first, capped at `limit`. Recipe-derived entries are
    /// FoodEntry rows like any other — no special-casing needed, they
    /// already carry a "recipe:" foodRefID and a normal displayName.
    static func recent(context: ModelContext, limit: Int = 10) -> [FoodEntry] {
        let descriptor = FetchDescriptor<FoodEntry>(sortBy: [SortDescriptor(\.loggedAt, order: .reverse)])
        guard let allEntries = try? context.fetch(descriptor) else { return [] }
        var seen = Set<String>()
        var result: [FoodEntry] = []
        for entry in allEntries {
            let key = entry.displayName.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(entry)
            if result.count == limit { break }
        }
        return result
    }
}
