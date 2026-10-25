import Foundation
import SwiftData
import LiftCore

/// A food the person entered once against a barcode, so the next scan of that
/// code finds it. LIFT-only (Coach never scans), so it is this app's model and
/// not LiftKit's. `per100g` is what they typed on the label's per-100 g basis;
/// a blank optional nutrient stays nil. `code` is `Barcode.normalised`.
/// The person's answer beats any dataset: when the barcode bundle exists, a
/// remembered code is looked up first.
@Model
final class RememberedFood {
    @Attribute(.unique) var code: String
    var name: String
    var brand: String?
    var per100g: NutritionFacts
    var servingGrams: Double?
    var rememberedAt: Date
    var updatedAt: Date

    init(code: String, name: String, brand: String? = nil, per100g: NutritionFacts,
         servingGrams: Double? = nil, rememberedAt: Date = .now, updatedAt: Date = .now) {
        self.code = code
        self.name = name
        self.brand = brand
        self.per100g = per100g
        self.servingGrams = servingGrams
        self.rememberedAt = rememberedAt
        self.updatedAt = updatedAt
    }
}
