import Foundation

/// The equipment someone has, which narrows exercise search to what they can
/// actually do. Kept as what they do *not* have, so nothing set is everything
/// owned and an untouched phone hides nothing.
///
/// An exercise whose equipment is not listed is never hidden: unknown is not
/// "needs something you lack", and hiding it would be a claim nobody made.
enum MyEquipment {
    static let storageKey = "equipmentNotOwned"

    struct Kind: Identifiable, Equatable {
        /// The value as `exercises.db` spells it.
        let id: String
        let displayName: String
    }

    /// Every equipment value in the bundled exercise data, in the order a
    /// gym is usually described. `MyEquipmentTests` checks the data has no
    /// value missing from this list.
    static let kinds: [Kind] = [
        Kind(id: "barbell", displayName: "Barbell"),
        Kind(id: "e-z curl bar", displayName: "EZ bar"),
        Kind(id: "dumbbell", displayName: "Dumbbells"),
        Kind(id: "kettlebells", displayName: "Kettlebells"),
        Kind(id: "cable", displayName: "Cable"),
        Kind(id: "machine", displayName: "Machines"),
        Kind(id: "bands", displayName: "Bands"),
        Kind(id: "medicine ball", displayName: "Medicine ball"),
        Kind(id: "exercise ball", displayName: "Exercise ball"),
        Kind(id: "foam roll", displayName: "Foam roller"),
        Kind(id: "body only", displayName: "Bodyweight"),
        Kind(id: "other", displayName: "Other"),
    ]

    static func normalised(_ equipment: String?) -> String {
        (equipment ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func allows(_ equipment: String?, notOwned: Set<String>) -> Bool {
        let value = normalised(equipment)
        return value.isEmpty || !notOwned.contains(value)
    }

    /// What to show, and how many were left out, so search can say so.
    static func filter<Item>(_ items: [Item], notOwned: Set<String>,
                             equipment: (Item) -> String?) -> (shown: [Item], leftOut: Int) {
        guard !notOwned.isEmpty else { return (items, 0) }
        let shown = items.filter { allows(equipment($0), notOwned: notOwned) }
        return (shown, items.count - shown.count)
    }

    static func load(from defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    /// Owning everything removes the key, rather than storing an empty list.
    static func save(_ notOwned: Set<String>, to defaults: UserDefaults = .standard) {
        if notOwned.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            defaults.set(notOwned.sorted(), forKey: storageKey)
        }
    }
}
