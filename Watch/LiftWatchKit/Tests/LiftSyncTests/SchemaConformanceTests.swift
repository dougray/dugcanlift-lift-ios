import XCTest
import LiftSync

/// Checks the wire types against the schema files themselves, in both
/// directions, rather than against key names copied into a test by hand.
///
/// `SyncEnvelopeTests` and friends pin spellings a person wrote down, which
/// is what caught drift while the phone and the watch each carried their own
/// copy of these types. Now both compile one copy, so the remaining way to
/// drift is between that copy and `Watch/contracts/*.schema.json`: a field
/// added to the Swift type and not the schema, or to the schema and not the
/// type. These tests read the schema files from the source tree:
///
/// - **Swift -> schema.** A value with every optional field filled in is
///   encoded, and every key, enum value, type, format and bound in the result
///   must be one the schema allows. Every schema property must also appear,
///   so a property the Swift type cannot carry is caught too.
/// - **Schema -> Swift.** A document with every schema property filled in is
///   generated from the schema, decoded through the same `messageBody`
///   bridge WatchConnectivity uses, and re-encoded; it must come back
///   identical, so nothing the schema describes is dropped on the way in.
final class SchemaConformanceTests: XCTestCase {

    // MARK: - SyncEnvelope

    func testEveryEventTheSwiftTypeKnowsIsInTheSchemaAndViceVersa() throws {
        let schema = try Schema(file: "workout-sync.schema.json")
        XCTAssertEqual(
            Set(SyncEnvelope.Event.allCases.map(\.rawValue)),
            try schema.enumValues(at: ["properties", "event"])
        )
        XCTAssertEqual(
            Set(SyncEnvelope.Origin.allCases.map(\.rawValue)),
            try schema.enumValues(at: ["properties", "origin"])
        )
        XCTAssertEqual(
            Set(WorkoutPlan.Source.allCases.map(\.rawValue)),
            try schema.enumValues(at: ["$defs", "plan", "properties", "source"])
        )
    }

    func testAFullyPopulatedEnvelopeEncodesToExactlyWhatTheSchemaDescribes() throws {
        let schema = try Schema(file: "workout-sync.schema.json")
        let envelope = SyncEnvelope(
            event: .planPushed,
            workoutID: UUID(uuidString: "6A2A8B6E-3D2F-4E77-9B4E-2C6A5E8C1D01")!,
            revision: 3,
            updatedAt: Date(timeIntervalSince1970: 1_758_358_800),
            origin: .ios,
            foodLog: FoodLogPayload(foodRefID: "usda:173944", amountGrams: 120,
                                    meal: "breakfast",
                                    loggedAt: Date(timeIntervalSince1970: 1_758_358_000)),
            plan: WorkoutPlan(
                name: "Push",
                source: .coachPlan,
                scheduledFor: "2026-09-20",
                exercises: [PlanExercise(
                    name: "Bench Press",
                    equipment: "barbell",
                    note: "Pause the first rep",
                    sets: [PrescribedSet(weightKg: 83.9, reps: 5, rpe: 8, restSeconds: 120,
                                         side: .left)],
                    lastPerformed: LastPerformed(weightKg: 81.6, reps: 6, rpe: 8.5,
                                                 performedOn: "2026-09-13"),
                    eachSide: true
                )]
            ),
            heartRate: SessionHeartRate(averageBpm: 128.5, maxBpm: 171)
        )

        let encoded = try envelope.messageBody()
        XCTAssertEqual(schema.violations(of: encoded, requireEveryProperty: true), [])
    }

    func testAnEnvelopeGeneratedFromTheSchemaDecodesWithNothingLost() throws {
        let schema = try Schema(file: "workout-sync.schema.json")
        let document = try XCTUnwrap(schema.sample() as? [String: Any])

        let decoded = try SyncEnvelope(messageBody: document)
        let reencoded = try decoded.messageBody()

        XCTAssertEqual(reencoded as NSDictionary, document as NSDictionary)
    }

    func testTheGeneratedEnvelopeIsItselfValid() throws {
        // Guards the generator above: a sample the schema would reject proves
        // nothing about the decoder.
        let schema = try Schema(file: "workout-sync.schema.json")
        let document = try XCTUnwrap(schema.sample() as? [String: Any])
        XCTAssertEqual(schema.violations(of: document, requireEveryProperty: true), [])
    }

    func testTheSchemaCatchesADriftedKey() throws {
        // And guards the checker: a renamed key must be reported, or every
        // test above passes vacuously.
        let schema = try Schema(file: "workout-sync.schema.json")
        var document = try XCTUnwrap(schema.sample() as? [String: Any])
        document["workoutID"] = document.removeValue(forKey: "workoutId")
        let violations = schema.violations(of: document, requireEveryProperty: true)
        XCTAssertTrue(violations.contains { $0.contains("workoutID") }, "\(violations)")
        XCTAssertTrue(violations.contains { $0.contains("workoutId") }, "\(violations)")
    }

    // MARK: - RecentFoodsSnapshot

    func testAFullyPopulatedSnapshotEncodesToExactlyWhatTheSchemaDescribes() throws {
        let schema = try Schema(file: "recent-foods-snapshot.schema.json")
        let snapshot = RecentFoodsSnapshot(
            items: [RecentFoodsSnapshot.Item(
                foodRefID: "usda:173944",
                displayName: "Bananas, raw",
                lastAmountGrams: 120,
                nutritionPer100g: WatchFood(name: "Bananas, raw", kcal: 89, protein: 1.09,
                                            fat: 0.33, carbs: 22.84, fibre: 2.6)
            )],
            generatedAt: Date(timeIntervalSince1970: 1_758_358_800)
        )
        XCTAssertEqual(schema.violations(of: try snapshot.messageBody(), requireEveryProperty: true), [])
    }

    func testASnapshotGeneratedFromTheSchemaDecodesWithNothingLost() throws {
        let schema = try Schema(file: "recent-foods-snapshot.schema.json")
        let document = try XCTUnwrap(schema.sample() as? [String: Any])
        XCTAssertEqual(schema.violations(of: document, requireEveryProperty: true), [])

        let reencoded = try RecentFoodsSnapshot(messageBody: document).messageBody()
        XCTAssertEqual(reencoded as NSDictionary, document as NSDictionary)
    }
}

// MARK: - A small JSON Schema reader
//
// Covers exactly the keywords the two contracts use: properties, required,
// $ref into $defs, items, enum, type (including a ["number", "null"] union),
// format uuid and date-time, pattern, minimum, maximum and exclusiveMinimum.
// A keyword it does not know fails the test rather than passing silently.

private struct Schema {
    let root: [String: Any]

    static let contracts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // LiftSyncTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // LiftWatchKit
        .deletingLastPathComponent()   // Watch
        .appendingPathComponent("contracts")

    private static let understood: Set<String> = [
        "$schema", "$defs", "$ref", "title", "description", "type", "properties",
        "required", "additionalProperties", "items", "enum", "format", "pattern",
        "minimum", "maximum", "exclusiveMinimum"
    ]

    init(file: String) throws {
        let data = try Data(contentsOf: Self.contracts.appendingPathComponent(file))
        root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        try Self.checkKeywords(root, path: file)
    }

    private static func checkKeywords(_ node: Any, path: String) throws {
        if let node = node as? [String: Any] {
            // Property names and $defs names are data, not keywords.
            for (key, value) in node {
                if path.hasSuffix(".properties") || path.hasSuffix(".$defs") {
                    try checkKeywords(value, path: "\(path).\(key)")
                } else {
                    guard understood.contains(key) else {
                        throw SchemaError.unknownKeyword("\(path).\(key)")
                    }
                    try checkKeywords(value, path: "\(path).\(key)")
                }
            }
        }
    }

    func enumValues(at path: [String]) throws -> Set<String> {
        var node: Any = root
        for key in path { node = try XCTUnwrap((node as? [String: Any])?[key], "no \(key)") }
        let values = try XCTUnwrap((node as? [String: Any])?["enum"] as? [String])
        return Set(values)
    }

    private func resolve(_ node: [String: Any]) -> [String: Any] {
        guard let ref = node["$ref"] as? String, ref.hasPrefix("#/$defs/") else { return node }
        let name = String(ref.dropFirst("#/$defs/".count))
        return (root["$defs"] as? [String: Any])?[name] as? [String: Any] ?? [:]
    }

    private func types(of node: [String: Any]) -> [String] {
        if let type = node["type"] as? String { return [type] }
        return node["type"] as? [String] ?? []
    }

    // MARK: Validation

    /// Everything about `value` the schema does not allow, as readable paths.
    /// With `requireEveryProperty`, a schema property missing from an object
    /// is a violation too.
    func violations(of value: Any, requireEveryProperty: Bool) -> [String] {
        var found: [String] = []
        check(value, against: root, path: "$", requireAll: requireEveryProperty, into: &found)
        return found.sorted()
    }

    private func check(_ value: Any, against rawNode: [String: Any], path: String,
                       requireAll: Bool, into found: inout [String]) {
        let node = resolve(rawNode)

        if let allowed = node["enum"] as? [String] {
            if let string = value as? String, allowed.contains(string) { return }
            found.append("\(path): \(value) is not one of \(allowed)")
            return
        }

        let types = types(of: node)
        if value is NSNull {
            if !types.contains("null") { found.append("\(path): null is not allowed") }
            return
        }

        if let object = value as? [String: Any] {
            guard types.contains("object") || node["properties"] != nil else {
                found.append("\(path): an object is not allowed here"); return
            }
            let properties = node["properties"] as? [String: Any] ?? [:]
            for key in object.keys where properties[key] == nil {
                found.append("\(path).\(key): not in the schema")
            }
            for key in node["required"] as? [String] ?? [] where object[key] == nil {
                found.append("\(path).\(key): required but missing")
            }
            if requireAll {
                for key in properties.keys where object[key] == nil {
                    found.append("\(path).\(key): in the schema but never encoded")
                }
            }
            for (key, child) in object {
                guard let childNode = properties[key] as? [String: Any] else { continue }
                check(child, against: childNode, path: "\(path).\(key)", requireAll: requireAll, into: &found)
            }
            return
        }

        if let array = value as? [Any] {
            guard types.contains("array") else { found.append("\(path): an array is not allowed here"); return }
            guard let items = node["items"] as? [String: Any] else { return }
            if requireAll && array.isEmpty { found.append("\(path): empty, so its items were never checked") }
            for (index, element) in array.enumerated() {
                check(element, against: items, path: "\(path)[\(index)]", requireAll: requireAll, into: &found)
            }
            return
        }

        if let string = value as? String {
            guard types.contains("string") else { found.append("\(path): a string is not allowed here"); return }
            switch node["format"] as? String {
            case "uuid" where UUID(uuidString: string) == nil:
                found.append("\(path): \(string) is not a uuid")
            case "date-time" where ISO8601DateFormatter().date(from: string) == nil:
                found.append("\(path): \(string) is not a date-time")
            default: break
            }
            if let pattern = node["pattern"] as? String,
               string.range(of: pattern, options: .regularExpression) == nil {
                found.append("\(path): \(string) does not match \(pattern)")
            }
            return
        }

        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            if !types.contains("boolean") { found.append("\(path): a boolean is not allowed here") }
            return
        }

        if let number = value as? NSNumber {
            let double = number.doubleValue
            if types.contains("integer") {
                if double != double.rounded() { found.append("\(path): \(double) is not an integer") }
            } else if !types.contains("number") {
                found.append("\(path): a number is not allowed here")
            }
            if let minimum = node["minimum"] as? Double, double < minimum {
                found.append("\(path): \(double) is below \(minimum)")
            }
            if let maximum = node["maximum"] as? Double, double > maximum {
                found.append("\(path): \(double) is above \(maximum)")
            }
            if let bound = node["exclusiveMinimum"] as? Double, double <= bound {
                found.append("\(path): \(double) is not above \(bound)")
            }
            return
        }

        found.append("\(path): \(type(of: value)) is not a JSON type this schema uses")
    }

    // MARK: Generation

    /// A document holding every property the schema describes, each with a
    /// value the schema accepts.
    func sample() -> Any { sample(root) }

    private func sample(_ rawNode: [String: Any]) -> Any {
        let node = resolve(rawNode)
        if let allowed = node["enum"] as? [String] { return allowed[allowed.count / 2] }
        let types = types(of: node)
        if let properties = node["properties"] as? [String: Any] {
            var object: [String: Any] = [:]
            for (key, child) in properties {
                object[key] = sample(child as? [String: Any] ?? [:])
            }
            return object
        }
        if types.contains("array"), let items = node["items"] as? [String: Any] {
            return [sample(items), sample(items)]
        }
        if types.contains("string") {
            switch node["format"] as? String {
            case "uuid": return "6A2A8B6E-3D2F-4E77-9B4E-2C6A5E8C1D01"
            case "date-time": return "2026-09-20T09:00:00Z"
            default: break
            }
            if node["pattern"] != nil { return "2026-09-20" }
            return "Bench Press"
        }
        if types.contains("boolean") {
            // `true`, because every boolean on these contracts is a flag
            // that is omitted when false: a sample of `false` would be a
            // document no sender ever writes.
            return true
        }
        if types.contains("integer") {
            let minimum = node["minimum"] as? Int ?? 0
            return max(minimum, 3)
        }
        if types.contains("number") { return 7.5 }
        return NSNull()
    }
}

private enum SchemaError: Error {
    case unknownKeyword(String)
}
