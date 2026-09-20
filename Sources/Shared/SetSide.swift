import Foundation

/// Which limb a set was performed with.
///
/// **Absent is "both", forever.** Every set ever stored before this feature
/// existed is a set with no side, and it must keep meaning what it meant: a
/// two-sided lift, or a single-arm lift whose sides nobody recorded. There is
/// deliberately no `.both` case to accidentally write into a column — `nil` is
/// the value, and no migration has to guess at history.
///
/// A left-arm row and a right-arm row are not the same lift, so side joins
/// name and equipment in the grouping key (see `LiftKey`). That is the same
/// reasoning equipment already carries: a cable pulldown and a machine
/// pulldown were merged into one zig-zagging trend line until equipment was
/// part of the identity, and averaging two limbs hides exactly the thing a
/// per-limb log exists to show.
enum SetSide: String, Codable, CaseIterable, Identifiable, Sendable {
    case left, right

    var id: String { rawValue }

    /// The one character a set row, a header count and a coach's session list
    /// all use: "185 x 5 L".
    var shortLabel: String { self == .left ? "L" : "R" }

    var displayName: String { self == .left ? "Left" : "Right" }

    var opposite: SetSide { self == .left ? .right : .left }

    // MARK: - SHARE-FORMAT

    /// The set tuple's `flags` byte, bits 1-2: 0 both, 1 left, 2 right.
    ///
    /// Bits rather than a seventh position because the tuple's length is the
    /// contract — a decoder that expects six fields keeps reading weight and
    /// reps out of an encoder that knows about sides, and simply cannot say
    /// which limb. That is the correct degradation; a longer tuple would be
    /// dropped whole by the decoders already in the field.
    var shareFlagBits: Int { self == .left ? 1 : 2 }

    /// Reads bits 1-2 of a `flags` byte. `3` is not a side and never written;
    /// like `0` it reads as both, so a future bit cannot turn a two-sided set
    /// into a left one.
    static func fromShareFlags(_ flags: Int) -> SetSide? {
        switch (flags >> 1) & 0b11 {
        case 1:  .left
        case 2:  .right
        default: nil
        }
    }

    // MARK: - BACKUP-FORMAT

    /// `"left"` / `"right"`, omitted from the JSON entirely when both. Named
    /// rather than packed, for the reason outdoor bests are objects in that
    /// file: a backup is read by humans and by three platforms, and a field
    /// nobody recognises has to survive being carried through.
    var backupValue: String { rawValue }

    /// Lenient on the way in: an unknown string is "both", not a failed
    /// restore, and a file written before this feature has no key at all.
    static func fromBackup(_ raw: Any?) -> SetSide? {
        guard let text = raw as? String else { return nil }
        return SetSide(rawValue: text.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

/// The name half of the lift identity, spelled the way the share link's
/// exercise dictionary spells it.
enum ExerciseKey {

    /// `"name|equipment"`, lowercased so a preference set on "Bulgarian Split
    /// Squat (Dumbbell)" is still found when the same lift arrives capitalised
    /// differently. This is an identity for *lookup*, never something shown.
    static func make(name: String, equipment: String?) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespaces).lowercased()
        let trimmedEquipment = (equipment ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return "\(trimmedName)|\(trimmedEquipment)"
    }
}

/// Whether a lift's *name* looks like one limb at a time.
///
/// The bundled exercise database has no "unilateral" column, so this is a
/// guess and is only ever used to pre-tick a toggle. It never decides
/// anything on its own: an exercise the lifter has answered for keeps the
/// answer they gave, including "no" on a name this says yes to. Lunge is in
/// the list and a walking lunge alternates without anyone caring to record
/// which leg — which is exactly why the lifter, not this function, has the
/// last word.
enum UnilateralGuess {

    /// Lowercased substrings. Hyphen and space spellings both appear in the
    /// database ("Single-Arm Row", "Single Arm Landmine Press").
    static let markers = [
        "single-arm", "single arm",
        "one-arm", "one arm",
        "single-leg", "single leg",
        "one-leg", "one leg",
        "bulgarian",
        "split squat",
        "pistol",
        "lunge",
        "step-up", "step up",
        "unilateral"
    ]

    static func looksUnilateral(name: String) -> Bool {
        let lowered = name.lowercased()
        return markers.contains { lowered.contains($0) }
    }
}

/// The per-exercise "log left and right separately" choice.
///
/// Stored as one JSON object in `UserDefaults` under `perSideExercises`,
/// keyed by `ExerciseKey`, rather than as a column on `ExerciseEntry`: the
/// choice belongs to the lift, not to one day's entry of it, and a preference
/// is not history. The functions are pure and take the raw string so the
/// rules can be tested without a view — the same reason `MacroFields` is a
/// value type in Cook.
///
/// A key that is absent means "never answered", which is why `isOn` returns
/// an optional: `nil` falls back to `UnilateralGuess`, and `false` is a real
/// answer that must outrank it.
enum PerSideLogging {

    static let storageKey = "perSideExercises"

    static func isOn(_ key: String, in raw: String) -> Bool? {
        decode(raw)[key]
    }

    /// What the set row should actually do: the lifter's answer if they gave
    /// one, otherwise the name's guess.
    static func effective(name: String, equipment: String?, in raw: String) -> Bool {
        isOn(ExerciseKey.make(name: name, equipment: equipment), in: raw)
            ?? UnilateralGuess.looksUnilateral(name: name)
    }

    static func setting(_ on: Bool, for key: String, in raw: String) -> String {
        var map = decode(raw)
        map[key] = on
        return encode(map)
    }

    static func decode(_ raw: String) -> [String: Bool] {
        guard let data = raw.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: Bool].self, from: data)
        else { return [:] }
        return map
    }

    static func encode(_ map: [String: Bool]) -> String {
        guard let data = try? JSONEncoder().encode(map),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
