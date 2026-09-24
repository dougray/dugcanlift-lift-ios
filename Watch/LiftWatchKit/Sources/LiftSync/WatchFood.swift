import Foundation

/// One food, per 100 g, as the bundled library and the export payload both
/// carry it. Deliberately not `FoodLogPayload`: that type identifies a food
/// by `foodRefID` for a phone that can resolve it, and the whole point of
/// the standalone path is that nothing downstream can.
public struct WatchFood: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var kcal: Double
    public var protein: Double
    public var fat: Double
    public var carbs: Double
    public var fibre: Double

    public init(name: String, kcal: Double, protein: Double,
                fat: Double, carbs: Double, fibre: Double) {
        self.name = name
        self.kcal = kcal
        self.protein = protein
        self.fat = fat
        self.carbs = carbs
        self.fibre = fibre
    }
}
