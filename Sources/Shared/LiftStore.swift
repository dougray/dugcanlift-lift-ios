import Foundation
import SwiftData
import LiftCore

/// Central SwiftData configuration.
///
/// The store lives in the App Group container rather than the app's private
/// Documents directory. This is the single decision that makes WidgetKit
/// possible: the widget extension runs in its own process and can only reach
/// files inside a container both targets are entitled to.
///
/// Change `appGroupID` to match the App Group you create in the Apple Developer
/// portal, and add the identical entitlement to BOTH the app target and the
/// widget extension target.
enum LiftStore {

    static let appGroupID = "group.com.dugcanlift.lift"

    /// The current schema. Defined by the newest `VersionedSchema` rather than
    /// listed by hand, so the migration plan and the container can never
    /// disagree about what shape the store is in — see `LiftSchemaVersions.swift`.
    static let schema = Schema(versionedSchema: LiftSchemaV8.self)

    /// Shared container. Both the app and the widget call this.
    static let shared: ModelContainer = makeContainer()

    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let configuration: ModelConfiguration

        if inMemory {
            configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )
        } else {
            configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                groupContainer: .identifier(appGroupID)
            )
        }

        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: LiftMigrationPlan.self,
                configurations: [configuration]
            )
        } catch {
            // NSLog, not print — print never reaches the unified log, so it is
            // invisible to `simctl spawn booted log stream`.
            NSLog("‼️ LIFT ModelContainer failed: %@", String(describing: error))

            #if DEBUG
            diagnoseSchema()

            // Schema drift the migration plan could not handle: delete the
            // store and retry once. DEBUG only — this destroys data, and the
            // fix for a real failure here is a migration stage in
            // LiftSchemaVersions.swift, not this branch.
            if let url = configuration.url as URL? {
                NSLog("‼️ LIFT deleting store at %@", url.path)
                for suffix in ["", "-shm", "-wal"] {
                    try? FileManager.default.removeItem(
                        at: URL(fileURLWithPath: url.path + suffix))
                }
                if let recovered = try? ModelContainer(
                    for: schema,
                    migrationPlan: LiftMigrationPlan.self,
                    configurations: [configuration]
                ) {
                    NSLog("‼️ LIFT recovered with a fresh store")
                    return recovered
                }
            }
            #endif

            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    #if DEBUG
    /// Builds an in-memory container for each model alone, then in cumulative
    /// groups. The first failure names the offending model — far faster than
    /// reading SwiftData's assertion, which does not identify it.
    static func diagnoseSchema() {
        let models: [(String, any PersistentModel.Type)] = [
            ("WorkoutDay", WorkoutDay.self),
            ("ExerciseEntry", ExerciseEntry.self),
            ("SetEntry", SetEntry.self),
            ("FoodEntry", FoodEntry.self),
            ("BodyMeasurement", BodyMeasurement.self)
        ]

        NSLog("‼️ LIFT --- schema diagnosis: individually ---")
        for (name, model) in models {
            let single = Schema([model])
            let config = ModelConfiguration(schema: single, isStoredInMemoryOnly: true)
            do {
                _ = try ModelContainer(for: single, configurations: [config])
                NSLog("‼️ LIFT   ok      %@", name)
            } catch {
                NSLog("‼️ LIFT   FAILED  %@ -> %@", name, String(describing: error))
            }
        }

        NSLog("‼️ LIFT --- schema diagnosis: cumulative ---")
        var accumulated: [any PersistentModel.Type] = []
        for (name, model) in models {
            accumulated.append(model)
            let partial = Schema(accumulated)
            let config = ModelConfiguration(schema: partial, isStoredInMemoryOnly: true)
            do {
                _ = try ModelContainer(for: partial, configurations: [config])
                NSLog("‼️ LIFT   ok      through %@", name)
            } catch {
                NSLog("‼️ LIFT   FAILED  adding %@ -> %@", name, String(describing: error))
                break
            }
        }
    }
    #endif

    /// Read-only context for the widget extension. Widgets should never write.
    static func widgetContext() -> ModelContext {
        let context = ModelContext(shared)
        context.autosaveEnabled = false
        return context
    }
}
