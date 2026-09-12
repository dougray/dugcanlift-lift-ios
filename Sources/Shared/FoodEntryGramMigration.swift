import Foundation
import SwiftData
import LiftCore

/// One-time (idempotent) backfill of `FoodEntry.amountGrams` for rows
/// logged before that field existed. Best-effort per the design spec: a row
/// with a known `servingGrams` gets an exact gram-equivalent computed and
/// stored; a row without one is left exactly as it was — no guessing, no
/// blocking, and safe to call on every launch (already-migrated or
/// already-determined-unconvertible rows are skipped).
enum FoodEntryGramMigration {
    static func run(context: ModelContext) {
        let descriptor = FetchDescriptor<FoodEntry>(
            predicate: #Predicate { $0.amountGrams == nil && $0.servingGrams != nil }
        )
        guard let candidates = try? context.fetch(descriptor), !candidates.isEmpty else { return }

        for entry in candidates {
            guard let servingGrams = entry.servingGrams else { continue }
            entry.amountGrams = entry.quantity * servingGrams
        }
        try? context.save()
    }
}
