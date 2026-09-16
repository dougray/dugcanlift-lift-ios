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
  GRDB access to the bundled reference database now lives in `LiftKit`'s
  `LiftReference` product (see "Shared code lives in LiftKit" below), not a
  local `Sources/Reference/` — that directory no longer exists here.
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

**A pasted recipe is edited, not reviewed.** `RecipeImportView` can review
because a page's JSON-LD is labelled — the publisher said which strings are
ingredients. A caption is prose, so `LiftCore.CaptionRecipe` only *proposes* a
split and `RecipePasteImportView` is an editor. Keep it that way, and do not
make the parser infer past what the text states: its title rule (the first line
or none) and its yield rule (a line must open with a yield word and carry a
number) are both pinned in the kit, and the looser versions silently removed a
real line or halved every macro in a dish. Social video is out of reach by
design — no site among TikTok, Instagram, Reels or YouTube publishes a
schema.org `Recipe` — so pasting the caption is the supported path, not a
workaround waiting on a better scraper.

**A shared route is opt-in and trimmed.** Send to Coach always carries runs,
walks and hikes as times, distances and bests (`o`, `ob`), but the map of the
newest one (`lr`) goes only when `coachShareLastRoute` is on, and it is off by
default. Even then the first and last 200 m are cut: a route usually starts and
ends at someone's front door, and a link sits in a coach's inbox indefinitely.
`CoachShare` only maps `OutdoorActivity` in — what is sent, the rounding, the
trim, the thinning and the polyline all live in LiftKit's `OutdoorShare`, and
`Tests/Fixtures/outdoor-share-*.json` were written by LIFT web. Copy them from
there; never regenerate them from this encoder, or they stop proving anything.

**Light and dark both exist, and System is the default.** `Theme`'s tokens
resolve per interface style (LiftKit 1.7.0). Apply `.liftAppearance()` — never
`.preferredColorScheme(.dark)` — on the root and on every sheet, since a sheet is
its own presentation. Draw cards with `LiftCard` or `.liftCardBackground()`, not
`.background(Theme.surface, ...)`, which leaves off the hairline light cards
need. Widgets follow the phone's appearance, not this setting: iOS does not let
an app choose a widget's colour scheme.

**Saturated fat, sugar and sodium are tracked, never targeted.** No goal, no
bar, nothing "over". nil means the source did not say — never zero — so a
day's total covers only the foods that recorded each value and says so when
that is not all of them ("from 3 of 5 foods"). Display rounding, `fx`/`fe` in
Send to Coach and `ux` from a plan all go through LiftKit's `ShareNutrients`,
so the phone and the coach read the same number. The rules are
`NutrientDetailsDisplay`, `FoodEntryEdit` and `RecipeMacroEntry`, not views.

**A struct a model stores is part of the schema.** SwiftData flattens
`NutritionFacts` into one column per field on FoodEntry, Recipe and
PlannedMeal, so a new field in LiftKit is a schema change here. LiftKit 1.9.0's
`saturatedFatG` needed `LiftSchemaV7` and a frozen seven-field copy; without it
every existing install failed to open its store (134504). Verify any schema
change by installing over a store the previous build wrote, not only in tests —
`Tests/Fixtures/v6-simulator.store` is one.

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
