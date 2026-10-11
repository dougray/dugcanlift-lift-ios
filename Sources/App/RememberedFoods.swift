import Foundation
import SwiftData
import LiftCore

/// The one place remembered foods are read and written, so the scanner, the
/// form, Edit and Forget, backups and the ref resolver agree.
@MainActor
enum RememberedFoods {
    static func find(code: String, in context: ModelContext) -> RememberedFood? {
        var descriptor = FetchDescriptor<RememberedFood>(predicate: #Predicate { $0.code == code })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Upserts. A correction keeps when it was first remembered and moves
    /// `updatedAt`, which is what a backup's newest-wins merge compares.
    @discardableResult
    static func remember(code: String, name: String, per100g: NutritionFacts,
                         in context: ModelContext, now: Date = .now) -> RememberedFood {
        if let existing = find(code: code, in: context) {
            existing.name = name
            existing.per100g = per100g
            existing.updatedAt = now
            try? context.save()
            return existing
        }
        let food = RememberedFood(code: code, name: name, per100g: per100g, rememberedAt: now, updatedAt: now)
        context.insert(food)
        try? context.save()
        return food
    }

    /// Entries already logged keep their name and nutrition: they are stored
    /// on the entry itself.
    static func forget(code: String, in context: ModelContext) {
        guard let food = find(code: code, in: context) else { return }
        context.delete(food)
        try? context.save()
    }
}

/// What a scanned or typed code turns out to be.
@MainActor
enum BarcodeLookup {
    enum Outcome: Equatable {
        case remembered(LoggableFood)
        case unknown(Barcode)
        case didNotScanCleanly
    }

    /// Remembered foods first; the barcode bundle (project 2) becomes a second
    /// source behind this same call, after them.
    static func look(up raw: String, symbology: BarcodeSymbology?, in context: ModelContext) -> Outcome {
        switch Barcode.read(raw, symbology: symbology) {
        case .failure: return .didNotScanCleanly
        case .success(let code):
            if let food = RememberedFoods.find(code: code.normalised, in: context) {
                return .remembered(LoggableFood(remembered: food))
            }
            return .unknown(code)
        }
    }
}
