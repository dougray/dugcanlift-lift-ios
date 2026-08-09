import Foundation
import SwiftData

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

    static let schema = Schema([
        WorkoutSession.self,
        ExerciseEntry.self,
        SetEntry.self,
        FoodEntry.self,
        BodyMeasurement.self
    ])

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
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // A container failure at launch means the schema and the on-disk
            // store disagree. In production, handle this with a migration plan
            // rather than a crash — see SchemaMigrationPlan.
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    /// Read-only context for the widget extension. Widgets should never write.
    static func widgetContext() -> ModelContext {
        let context = ModelContext(shared)
        context.autosaveEnabled = false
        return context
    }
}

/// Stable day bucketing for "today's totals" queries.
///
/// Storing a normalised string key alongside the real timestamp means a
/// day-scoped fetch is an indexed string comparison instead of a date-range
/// predicate, and — more importantly — a workout logged in Austin stays on the
/// day it was logged even if the user opens the app in Tokyo.
enum DayKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func make(from date: Date, timeZone: TimeZone = .current) -> String {
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    static var today: String { make(from: .now) }
}
