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
///
/// **The terms are matched as whole words, and the list is one list across
/// four builds**: LIFT web's `UNILATERAL_TERMS` (`lift/sides.js`), LIFT for
/// Android's `PerSideLogging.UNILATERAL_TERMS`, Coach iPhone's
/// `UnilateralGuess` and this one. Change a term in all four or in none;
/// `testTheTermListIsTheOneTheOtherThreeBuildsCarry` pins this copy.
///
/// This file carried a substring rule until now, and a substring fires on the
/// inside of a longer word: "lunge" ticked "Cold Plunge", and "step up" would
/// tick a stepmill spelled "Step Up Mill". A whole-word rule cannot see the
/// shorter term inside the longer word either, which is why both numbers of
/// each term are listed rather than matched by prefix ("lunge", "lunges") and
/// why the "-ed" spellings are listed too — "One-Legged Deadlift" is the same
/// lift as "One-Leg Deadlift".
enum UnilateralGuess {

    /// Lowercased, single-spaced terms. Punctuation is not part of a name, so
    /// "Single-Arm Row", "Single Arm Landmine Press" and "SINGLE_ARM ROW" all
    /// carry the one term "single arm".
    static let terms = [
        "single arm", "one arm", "1 arm", "single handed",
        "single leg", "one leg", "1 leg", "single limb",
        "one legged", "single legged", "one armed", "single armed",
        "bulgarian", "split squat", "split squats",
        "pistol", "pistols", "lunge", "lunges",
        "step up", "step ups", "stepup", "stepups",
        "unilateral",
    ]

    /// Letters and digits only, single-spaced, padded so a term can be
    /// matched with a space on each side.
    private static func normalise(_ name: String) -> String {
        let cleaned = name.lowercased().unicodeScalars.map {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
                ? String($0) : " "
        }.joined()
        return " " + cleaned.split(separator: " ").joined(separator: " ") + " "
    }

    static func looksUnilateral(name: String) -> Bool {
        let padded = normalise(name)
        return terms.contains { padded.contains(" \($0) ") }
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
