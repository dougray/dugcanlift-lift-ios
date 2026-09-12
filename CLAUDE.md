# Lift — iOS

Native SwiftUI rewrite of the Lift wellness PWA. Workout and food tracking,
serverless, all user data on device.

## Build commands

```bash
make doctor     # verify tooling
make project    # regenerate Lift.xcodeproj from project.yml
make build      # build for simulator
make test       # run unit tests
make run        # build, install, launch
make logs       # tail app logs
```

Never edit `Lift.xcodeproj` — it is generated and gitignored. To change targets,
entitlements, Info.plist keys or capabilities, edit `project.yml` and run
`make project`.

## Architecture

- **`Sources/Shared/`** — SwiftData models and store config. Compiled into BOTH
  the app and widget targets. Anything added here must not import GRDB or any
  app-only dependency.
- **`Sources/App/`** — SwiftUI views, view models, HealthKit, notifications.
- **`Sources/Reference/`** — GRDB access to the bundled read-only SQLite
  reference database. App target only.
- **`Sources/Widgets/`** — WidgetKit extension and Live Activities.

The SwiftData store lives in the App Group container
(`group.com.dugcanlift.lift`) so the widget extension can read it. Do not move it
to the app's private container.

## Conventions that matter

**Snapshot reference data on write.** `FoodEntry` and `ExerciseEntry` copy the
name and nutrition values at log time rather than storing only a foreign key
into the reference database. Reference data changes between app releases; user
history must not. Never resolve display values by joining to `reference.db` at
read time.

**Weights are always kilograms.** Every stored weight is metric. `WeightUnit`
handles display conversion at the view layer only. Never persist pounds.

**Set `dayKey` whenever you set a date.** Day-scoped queries use the normalised
string key, not date-range predicates. The two must stay consistent.

**HealthKit writes must be idempotent.** Check `healthKitUUID` before writing;
set it after. Background sync retries, and duplicated Health entries are very
visible to users.

**Reload widget timelines after writes.** SwiftData does not notify the
extension. Call `WidgetCenter.shared.reloadAllTimelines()` after any mutation
that changes widget content.

## Constraints

- iOS 17.0 minimum (SwiftData).
- No backend. No remote push — reminders are local notifications via
  `UNUserNotificationCenter`.
- Everything must work fully offline, including food and exercise search.
- Widgets cannot open SQLite. They render from SwiftData snapshot fields only.

## Shared code lives in LiftKit

Domain models, wire codecs, the theme and day keys live in
`dugcanlift-kit`, not here. Two products, and the split matters:

- **`LiftCore`** — no SQLite dependency, so LIFT's widget extension can
  link it.
- **`LiftReference`** — GRDB and the 2.3 MB of reference databases. Apps
  only. Adding this to a widget target would hand it a SQLite dependency
  and data it never opens.

A change there reaches two shipped apps. `@Model` types are shared, so a
property change is a schema change for both — and `lift-ios`'s
`LiftSchemaVersions.swift` explains what that costs.

Day keys are **local**, and day arithmetic goes through `Calendar`. Never
`now - days * 86400`: it repeats a day across a DST fall-back.
