import WidgetKit
import SwiftUI
import SwiftData
import LiftCore

@main
struct LiftWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
    }
}

struct TodayEntry: TimelineEntry {
    let date: Date
    let calories: Double
    let proteinG: Double
    let workoutCount: Int

    static let placeholder = TodayEntry(
        date: .now, calories: 1420, proteinG: 98, workoutCount: 1
    )
}

struct TodayProvider: TimelineProvider {

    func placeholder(in context: Context) -> TodayEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(context.isPreview ? .placeholder : load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        // Reloads are driven by the app calling reloadAllTimelines() after a
        // write. This scheduled refresh is only a backstop so the widget rolls
        // over to the new day even if the app is never opened.
        let midnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86_400))
        completion(Timeline(entries: [load()], policy: .after(midnight)))
    }

    /// Reads the shared App Group store. Note this touches only SwiftData —
    /// the widget process never opens the reference database, which is why
    /// entries carry snapshot fields.
    private func load() -> TodayEntry {
        let context = LiftStore.widgetContext()
        let key = DayKey.today

        let food = (try? context.fetch(LiftQueries.foodEntries(on: key))) ?? []
        let days = (try? context.fetch(WorkoutQueries.day(key))) ?? []
        let totals = food.totalNutrition

        return TodayEntry(
            date: .now,
            calories: totals.calories,
            proteinG: totals.proteinG,
            workoutCount: days.first.map { $0.totalSetCount > 0 ? 1 : 0 } ?? 0
        )
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LiftToday", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Calories, protein and workouts logged today.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct TodayWidgetView: View {
    let entry: TodayEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Today", systemImage: "bolt.heart")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(entry.calories, format: .number.precision(.fractionLength(0)))
                .font(.system(.title, design: .rounded, weight: .bold))
                .contentTransition(.numericText())
            Text("kcal")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                stat("\(Int(entry.proteinG))g", "protein")
                if entry.workoutCount > 0 {
                    stat("\(entry.workoutCount)", "workout")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.footnote.weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
