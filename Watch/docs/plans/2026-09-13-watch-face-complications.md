# Watch Face Complications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Apple Watch face two LIFT complications — macros against goal, steps against goal — and make the macros one a one-tap portal into the watch's food log.

**Architecture:** All logic that can be tested without a simulator lives in the LiftKit Swift package and is covered by `swift test`. A new `LiftWatchWidgets` app-extension target holds only SwiftUI views and `TimelineProvider`s, which read the same `StandaloneFoodLog` the app writes — via a new App Group suite, because an extension cannot see the app's container. Every number is computed on the watch; nothing here depends on the phone.

**Tech Stack:** Swift 5.9, SwiftUI, WidgetKit, HealthKit, XcodeGen, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-13-watch-face-complications-design.md`

## Global Constraints

- Swift 5.9. LiftKit platforms are `.watchOS(.v10)`, `.iOS(.v17)`, `.macOS(.v14)` — do not raise them.
- App Group identifier: `group.com.dugcanlift.watch`
- Bundle ids: app `com.dugcanlift.watch`, extension `com.dugcanlift.watch.widgets`
- Widget kinds, exact strings: `LiftMacros`, `LiftSteps`
- URL scheme: `liftwatch`, single route `liftwatch://log`
- Day boundaries are **local Calendar** operations. Never `86_400` arithmetic, never UTC.
- **Never delete from the source `UserDefaults` suite.** Issue #4 was data loss in `StandaloneFoodLog`, and until a QR code is scanned that store is the only copy of the log in existence.
- `project.yml` is the source of truth. After editing it run `xcodegen generate` from `apple/`. Never hand-edit `LiftWatch.xcodeproj`.
- **Every "expected: FAIL" step requires pasting the actual failure output into the commit or task report.** A test asserted to fail without its failure text quoted is not evidence. This plan's own code is a likely defect source — treat it as a draft to verify, not as correct.
- Builds and tests run in the **foreground**. No backgrounded build commands.
- LiftKit tests: `swift test --package-path LiftKit` run from `apple/`.
- Watch build: `xcodebuild -project LiftWatch.xcodeproj -scheme LiftWatch -destination 'generic/platform=watchOS' build` run from `apple/`.

---

### Task 1: Today's nutrition totals

**Files:**
- Create: `apple/LiftKit/Sources/LiftKit/TodayTotals.swift`
- Test: `apple/LiftKit/Tests/LiftKitTests/TodayTotalsTests.swift`

**Interfaces:**
- Consumes: `LoggedFood`, `WatchFood` (existing, `StandaloneFoodLog.swift` / `WatchFood.swift`)
- Produces: `NutritionTotals(kcal:protein:carbs:fat:)`, `NutritionTotals.zero`, `TodayTotals.totals(from:on:calendar:) -> NutritionTotals`

- [ ] **Step 1: Write the failing test**

Create `apple/LiftKit/Tests/LiftKitTests/TodayTotalsTests.swift`:

```swift
import XCTest
@testable import LiftKit

final class TodayTotalsTests: XCTestCase {

    private let zone = "America/New_York"

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: zone)!
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: value)!
    }

    /// Oats, per 100 g, from the bundled library.
    private func entry(grams: Double, at when: Date) -> LoggedFood {
        LoggedFood(food: WatchFood(name: "Oats, rolled, dry", kcal: 379, protein: 13.2,
                                   fat: 6.5, carbs: 67.7, fibre: 10.1),
                   grams: grams, meal: .breakfast, loggedAt: when)
    }

    func testTotalsScaleByGrams() {
        let reference = date("2026-09-13 12:00")
        let totals = TodayTotals.totals(from: [entry(grams: 50, at: reference)],
                                        on: reference, calendar: calendar())
        XCTAssertEqual(totals.kcal, 189.5, accuracy: 0.001)
        XCTAssertEqual(totals.protein, 6.6, accuracy: 0.001)
        XCTAssertEqual(totals.carbs, 33.85, accuracy: 0.001)
        XCTAssertEqual(totals.fat, 3.25, accuracy: 0.001)
    }

    func testEntriesSumTogether() {
        let reference = date("2026-09-13 12:00")
        let totals = TodayTotals.totals(from: [entry(grams: 50, at: reference),
                                               entry(grams: 50, at: reference)],
                                        on: reference, calendar: calendar())
        XCTAssertEqual(totals.kcal, 379, accuracy: 0.001)
    }

    func testLateEveningEntryCountsAsToday() {
        // 23:30 local is the same local day as noon. A UTC boundary files this
        // as tomorrow and the evening's food vanishes off the face.
        let reference = date("2026-09-13 12:00")
        let totals = TodayTotals.totals(from: [entry(grams: 100, at: date("2026-09-13 23:30"))],
                                        on: reference, calendar: calendar())
        XCTAssertEqual(totals.kcal, 379, accuracy: 0.001)
    }

    func testYesterdayIsExcluded() {
        let reference = date("2026-09-13 12:00")
        let totals = TodayTotals.totals(from: [entry(grams: 100, at: date("2026-09-12 23:30"))],
                                        on: reference, calendar: calendar())
        XCTAssertEqual(totals, .zero)
    }

    func testDSTFallBackDayFoldsWholeDay() {
        // 2026-11-01 is a 25-hour day in America/New_York. Seconds arithmetic
        // gets this day wrong; Calendar does not.
        let reference = date("2026-11-01 01:00")
        let totals = TodayTotals.totals(from: [entry(grams: 100, at: date("2026-11-01 23:30"))],
                                        on: reference, calendar: calendar())
        XCTAssertEqual(totals.kcal, 379, accuracy: 0.001)
    }

    func testNoEntriesIsZeroNotNil() {
        XCTAssertEqual(TodayTotals.totals(from: [], on: date("2026-09-13 12:00"),
                                          calendar: calendar()), .zero)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path LiftKit --filter TodayTotalsTests`
Expected: FAIL to compile, `cannot find 'TodayTotals' in scope`.
Paste the actual compiler output into the task report.

- [ ] **Step 3: Write the implementation**

Create `apple/LiftKit/Sources/LiftKit/TodayTotals.swift`:

```swift
import Foundation

/// Calories and the three macros the rectangular complication shows.
///
/// `WatchFood` also carries fibre; it is deliberately absent here. The slot
/// holds three lines and fibre is the least glanceable of the four.
public struct NutritionTotals: Equatable, Sendable {
    public var kcal: Double
    public var protein: Double
    public var carbs: Double
    public var fat: Double

    public static let zero = NutritionTotals(kcal: 0, protein: 0, carbs: 0, fat: 0)

    public init(kcal: Double, protein: Double, carbs: Double, fat: Double) {
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
    }
}

public enum TodayTotals {

    /// Folds every entry logged on the same **local** day as `reference`.
    ///
    /// Day membership is `Calendar.isDate(_:inSameDayAs:)` — never arithmetic
    /// on a timestamp. A UTC boundary misfiles an evening log as tomorrow,
    /// and 86,400-second arithmetic repeats or skips a day across a DST
    /// change. `StandaloneFoodLog.live` documents the same reasoning for its
    /// own 60-day window.
    public static func totals(from entries: [LoggedFood],
                              on reference: Date = Date(),
                              calendar: Calendar = .current) -> NutritionTotals {
        entries
            .filter { calendar.isDate($0.loggedAt, inSameDayAs: reference) }
            .reduce(into: NutritionTotals.zero) { totals, entry in
                let per100g = entry.grams / 100
                totals.kcal += entry.food.kcal * per100g
                totals.protein += entry.food.protein * per100g
                totals.carbs += entry.food.carbs * per100g
                totals.fat += entry.food.fat * per100g
            }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path LiftKit --filter TodayTotalsTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add apple/LiftKit/Sources/LiftKit/TodayTotals.swift apple/LiftKit/Tests/LiftKitTests/TodayTotalsTests.swift
git commit -m "feat(kit): fold today's logged food into nutrition totals"
```

---

### Task 2: Goal store

**Files:**
- Create: `apple/LiftKit/Sources/LiftKit/GoalStore.swift`
- Test: `apple/LiftKit/Tests/LiftKitTests/GoalStoreTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces: `Goals(calories:protein:carbs:fat:steps:)`, `Goals.fallback`, `GoalStore(defaults:)`, `GoalStore.goals -> Goals`, `GoalStore.save(_:)`

- [ ] **Step 1: Write the failing test**

Create `apple/LiftKit/Tests/LiftKitTests/GoalStoreTests.swift`:

```swift
import XCTest
@testable import LiftKit

final class GoalStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "GoalStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testEmptyStoreReturnsTheIOSDefaults() {
        XCTAssertEqual(GoalStore(defaults: defaults).goals, .fallback)
        XCTAssertEqual(Goals.fallback.calories, 1748)
        XCTAssertEqual(Goals.fallback.protein, 160)
        XCTAssertEqual(Goals.fallback.carbs, 167)
        XCTAssertEqual(Goals.fallback.fat, 49)
        XCTAssertEqual(Goals.fallback.steps, 10_000)
    }

    func testSavedGoalsSurviveANewInstance() {
        let goals = Goals(calories: 2300, protein: 180, carbs: 200, fat: 60, steps: 12_000)
        GoalStore(defaults: defaults).save(goals)
        XCTAssertEqual(GoalStore(defaults: defaults).goals, goals)
    }

    func testUnreadableStoredValueFallsBackInsteadOfCrashing() {
        defaults.set(Data("not json".utf8), forKey: "com.dugcanlift.lift.goals")
        XCTAssertEqual(GoalStore(defaults: defaults).goals, .fallback)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path LiftKit --filter GoalStoreTests`
Expected: FAIL to compile, `cannot find 'GoalStore' in scope`.
Paste the actual output.

- [ ] **Step 3: Write the implementation**

Create `apple/LiftKit/Sources/LiftKit/GoalStore.swift`:

```swift
import Foundation

/// The daily targets the complications measure against.
public struct Goals: Codable, Equatable, Sendable {
    public var calories: Double
    public var protein: Double
    public var carbs: Double
    public var fat: Double
    public var steps: Double

    /// Matches LIFT iOS's own `@AppStorage` defaults, so a watch that has
    /// never been told otherwise shows the targets the phone would show
    /// rather than a face full of zeroes.
    public static let fallback = Goals(calories: 1748, protein: 160,
                                       carbs: 167, fat: 49, steps: 10_000)

    public init(calories: Double, protein: Double, carbs: Double,
                fat: Double, steps: Double) {
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.steps = steps
    }
}

/// `UserDefaults`-backed, following `RecentFoodsSnapshotStore` — one small,
/// infrequently written JSON blob.
///
/// Goals live on the phone as plain `@AppStorage` in `UserDefaults.standard`
/// and are unreachable from a watch with no companion app, which is why this
/// store exists at all. If a transport ever lands, a phone snapshot
/// overwrites this and the watch's Goals screen becomes a fallback.
public final class GoalStore {
    private let defaults: UserDefaults
    private let key = "com.dugcanlift.lift.goals"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Never throws and never returns nil: a complication with no goals to
    /// measure against has nothing to say, so an unreadable value falls back
    /// rather than propagating.
    public var goals: Goals {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Goals.self, from: data) else {
            return .fallback
        }
        return decoded
    }

    public func save(_ goals: Goals) {
        guard let data = try? JSONEncoder().encode(goals) else { return }
        defaults.set(data, forKey: key)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path LiftKit --filter GoalStoreTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add apple/LiftKit/Sources/LiftKit/GoalStore.swift apple/LiftKit/Tests/LiftKitTests/GoalStoreTests.swift
git commit -m "feat(kit): add watch-local goal store"
```

---

### Task 3: App Group suite and the copy-forward migration

**Files:**
- Create: `apple/LiftKit/Sources/LiftKit/SharedDefaults.swift`
- Modify: `apple/LiftKit/Sources/LiftKit/StandaloneFoodLog.swift:65-71` (expose storage keys)
- Modify: `apple/LiftWatch/WorkoutSessionModel.swift:19` (point the log at the group suite)
- Modify: `apple/LiftWatch/LiftWatchApp.swift:19-24` (run the migration before anything reads)
- Test: `apple/LiftKit/Tests/LiftKitTests/StandaloneFoodLogMigrationTests.swift`

**Interfaces:**
- Consumes: `StandaloneFoodLog` (existing)
- Produces: `SharedDefaults.appGroupIdentifier`, `SharedDefaults.group -> UserDefaults`, `StandaloneFoodLog.storageKeys -> [String]`, `StandaloneFoodLogMigration.copyForward(from:to:) -> Int`

- [ ] **Step 1: Write the failing test**

Create `apple/LiftKit/Tests/LiftKitTests/StandaloneFoodLogMigrationTests.swift`:

```swift
import XCTest
@testable import LiftKit

final class StandaloneFoodLogMigrationTests: XCTestCase {

    private var source: UserDefaults!
    private var destination: UserDefaults!
    private let sourceSuite = "StandaloneFoodLogMigrationTests.source"
    private let destinationSuite = "StandaloneFoodLogMigrationTests.destination"

    override func setUp() {
        super.setUp()
        source = UserDefaults(suiteName: sourceSuite)
        destination = UserDefaults(suiteName: destinationSuite)
        source.removePersistentDomain(forName: sourceSuite)
        destination.removePersistentDomain(forName: destinationSuite)
    }

    override func tearDown() {
        source.removePersistentDomain(forName: sourceSuite)
        destination.removePersistentDomain(forName: destinationSuite)
        source = nil
        destination = nil
        super.tearDown()
    }

    private func entry() -> LoggedFood {
        LoggedFood(food: WatchFood(name: "Oats, rolled, dry", kcal: 379, protein: 13.2,
                                   fat: 6.5, carbs: 67.7, fibre: 10.1),
                   grams: 50, meal: .breakfast, loggedAt: .now)
    }

    func testEntriesAppearInTheDestination() {
        StandaloneFoodLog(defaults: source).append(entry())
        StandaloneFoodLogMigration.copyForward(from: source, to: destination)
        XCTAssertEqual(StandaloneFoodLog(defaults: destination).entries.count, 1)
    }

    /// The one that matters. Issue #4 was data loss in this store, and until
    /// a QR code is scanned it is the only copy of the log in existence.
    func testSourceStillHoldsItsEntriesAfterMigrating() {
        StandaloneFoodLog(defaults: source).append(entry())
        StandaloneFoodLogMigration.copyForward(from: source, to: destination)
        XCTAssertEqual(StandaloneFoodLog(defaults: source).entries.count, 1)
    }

    func testSkippedCountMigratesToo() {
        StandaloneFoodLog(defaults: source).recordSkipped()
        StandaloneFoodLogMigration.copyForward(from: source, to: destination)
        XCTAssertEqual(StandaloneFoodLog(defaults: destination).skippedCount, 1)
    }

    func testSecondRunCopiesNothing() {
        StandaloneFoodLog(defaults: source).append(entry())
        XCTAssertEqual(StandaloneFoodLogMigration.copyForward(from: source, to: destination), 1)
        XCTAssertEqual(StandaloneFoodLogMigration.copyForward(from: source, to: destination), 0)
    }

    /// Once the group suite is live it is authoritative. A later copy must
    /// never overwrite food logged after the migration with the stale
    /// pre-migration copy still sitting in the old suite.
    func testDestinationIsNeverClobbered() {
        StandaloneFoodLog(defaults: source).append(entry())
        StandaloneFoodLogMigration.copyForward(from: source, to: destination)
        StandaloneFoodLog(defaults: destination).append(entry())
        StandaloneFoodLogMigration.copyForward(from: source, to: destination)
        XCTAssertEqual(StandaloneFoodLog(defaults: destination).entries.count, 2)
    }

    func testCopyingASuiteOntoItselfIsANoOp() {
        StandaloneFoodLog(defaults: source).append(entry())
        XCTAssertEqual(StandaloneFoodLogMigration.copyForward(from: source, to: source), 0)
        XCTAssertEqual(StandaloneFoodLog(defaults: source).entries.count, 1)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path LiftKit --filter StandaloneFoodLogMigrationTests`
Expected: FAIL to compile, `cannot find 'StandaloneFoodLogMigration' in scope`.
Paste the actual output.

- [ ] **Step 3: Expose the storage keys**

In `apple/LiftKit/Sources/LiftKit/StandaloneFoodLog.swift`, replace the three private key constants:

```swift
    /// Every defaults key this store owns, in one place so the App Group
    /// migration copies all of them. Duplicated string literals that drift
    /// would silently migrate only part of the log.
    public static let storageKeys = [
        "com.dugcanlift.lift.standaloneFoodLog",
        "com.dugcanlift.lift.standaloneFoodLog.skippedCount",
        "com.dugcanlift.lift.standaloneFoodLog.unreadable"
    ]

    private let key = StandaloneFoodLog.storageKeys[0]
    private let skippedCountKey = StandaloneFoodLog.storageKeys[1]
    /// Where a blob that could not be parsed at all is set aside, so that
    /// replacing it is never the same thing as destroying it.
    private let quarantineKey = StandaloneFoodLog.storageKeys[2]
```

- [ ] **Step 4: Write the migration**

Create `apple/LiftKit/Sources/LiftKit/SharedDefaults.swift`:

```swift
import Foundation

public enum SharedDefaults {
    public static let appGroupIdentifier = "group.com.dugcanlift.watch"

    /// Falls back to `.standard` rather than trapping. A build whose
    /// entitlement is missing must still log food — its widgets will read an
    /// empty store, which is recoverable. Refusing to run is not.
    public static var group: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }
}

public enum StandaloneFoodLogMigration {

    /// Copies the food log into the App Group suite, which is the only suite
    /// a widget extension can read.
    ///
    /// **Copies. Never deletes.** Until a QR code is scanned this log is the
    /// only copy that exists anywhere, and issue #4 was data loss in exactly
    /// this store. A move would be the same defect wearing a different hat.
    ///
    /// Per key and skip-if-present, so it is idempotent and never clobbers a
    /// destination that has moved on: after the first run the group suite is
    /// authoritative and this becomes a no-op.
    ///
    /// - Returns: how many keys were copied, for tests and for a log line.
    @discardableResult
    public static func copyForward(from source: UserDefaults,
                                   to destination: UserDefaults) -> Int {
        guard source !== destination else { return 0 }
        var copied = 0
        for key in StandaloneFoodLog.storageKeys {
            guard destination.object(forKey: key) == nil,
                  let value = source.object(forKey: key) else { continue }
            destination.set(value, forKey: key)
            copied += 1
        }
        return copied
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --package-path LiftKit --filter StandaloneFoodLogMigrationTests`
Expected: PASS, 6 tests.

- [ ] **Step 6: Run the whole suite to prove the key refactor broke nothing**

Run: `swift test --package-path LiftKit`
Expected: PASS, including the existing `StandaloneFoodLogTests` and `StandaloneFoodLogDurabilityTests`.

- [ ] **Step 7: Point the app at the group suite**

In `apple/LiftWatch/WorkoutSessionModel.swift`, change line 19:

```swift
    /// The App Group suite, not `.standard`: the widget extension is a
    /// separate process with its own container and can only see this one.
    let foodLog = StandaloneFoodLog(defaults: SharedDefaults.group)
```

In `apple/LiftWatch/LiftWatchApp.swift`, as the first statement of `init()`:

```swift
    init() {
        // Before anything reads the log. Copies the pre-App-Group log into
        // the group suite; the old suite is left exactly as it was.
        StandaloneFoodLogMigration.copyForward(from: .standard, to: SharedDefaults.group)

        let session = WorkoutSessionModel()
```

- [ ] **Step 8: Build the watch app**

Run: `xcodebuild -project LiftWatch.xcodeproj -scheme LiftWatch -destination 'generic/platform=watchOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 9: Commit**

```bash
git add apple/LiftKit/Sources/LiftKit/SharedDefaults.swift apple/LiftKit/Sources/LiftKit/StandaloneFoodLog.swift apple/LiftKit/Tests/LiftKitTests/StandaloneFoodLogMigrationTests.swift apple/LiftWatch/WorkoutSessionModel.swift apple/LiftWatch/LiftWatchApp.swift
git commit -m "feat(watch): move the food log into an App Group suite, copying forward"
```

---

### Task 4: The macros complication

Includes the extension target itself, because nothing else needs it yet.

**Files:**
- Create: `apple/LiftKit/Sources/LiftKit/MacroFormatter.swift`
- Create: `apple/LiftKit/Sources/LiftKit/WatchRoute.swift`
- Create: `apple/LiftWatchWidgets/LiftWatchWidgets.swift`
- Create: `apple/LiftWatchWidgets/MacrosComplication.swift`
- Modify: `apple/project.yml` (App Group on the app; new extension target)
- Modify: `apple/LiftWatch/WorkoutSessionModel.swift:129-131` (reload on write)
- Test: `apple/LiftKit/Tests/LiftKitTests/MacroFormatterTests.swift`
- Test: `apple/LiftKit/Tests/LiftKitTests/WatchRouteTests.swift`

**Interfaces:**
- Consumes: `NutritionTotals`, `TodayTotals.totals(from:on:calendar:)`, `Goals`, `GoalStore`, `SharedDefaults.group`, `StandaloneFoodLog`
- Produces: `Readout(text:isOverGoal:)`, `MacroFormatter.calories(_:goals:locale:) -> Readout`, `MacroFormatter.macros(_:goals:locale:) -> [Readout]`, `WatchRoute.foodLog`, `WatchRoute.init?(url:)`, `WatchRoute.url -> URL`, widget kind `"LiftMacros"`

- [ ] **Step 1: Write the failing formatter and route tests**

Create `apple/LiftKit/Tests/LiftKitTests/MacroFormatterTests.swift`:

```swift
import XCTest
@testable import LiftKit

final class MacroFormatterTests: XCTestCase {

    private let locale = Locale(identifier: "en_US_POSIX")
    private let goals = Goals(calories: 2300, protein: 160, carbs: 167, fat: 49, steps: 10_000)

    private func totals(kcal: Double, protein: Double, carbs: Double, fat: Double) -> NutritionTotals {
        NutritionTotals(kcal: kcal, protein: protein, carbs: carbs, fat: fat)
    }

    func testCalorieLineReadsAsConsumedOverGoal() {
        let readout = MacroFormatter.calories(totals(kcal: 1420, protein: 0, carbs: 0, fat: 0),
                                              goals: goals, locale: locale)
        XCTAssertEqual(readout.text, "1,420 / 2,300 kcal")
        XCTAssertFalse(readout.isOverGoal)
    }

    func testNothingLoggedStillShowsTheGoal() {
        let readout = MacroFormatter.calories(.zero, goals: goals, locale: locale)
        XCTAssertEqual(readout.text, "0 / 2,300 kcal")
    }

    func testExactlyAtGoalIsNotOver() {
        let readout = MacroFormatter.calories(totals(kcal: 2300, protein: 0, carbs: 0, fat: 0),
                                              goals: goals, locale: locale)
        XCTAssertFalse(readout.isOverGoal)
    }

    func testOverGoalIsFlagged() {
        let readout = MacroFormatter.calories(totals(kcal: 2450, protein: 0, carbs: 0, fat: 0),
                                              goals: goals, locale: locale)
        XCTAssertTrue(readout.isOverGoal)
    }

    func testMacrosAreAlwaysThreeInProteinCarbsFatOrder() {
        let readouts = MacroFormatter.macros(totals(kcal: 0, protein: 98, carbs: 142, fat: 44),
                                             goals: goals, locale: locale)
        XCTAssertEqual(readouts.count, 3)
        XCTAssertEqual(readouts[0].text, "P 98/160")
        XCTAssertEqual(readouts[1].text, "C 142/167")
        XCTAssertEqual(readouts[2].text, "F 44/49")
    }

    func testOnlyTheOverGoalMacroIsFlagged() {
        let readouts = MacroFormatter.macros(totals(kcal: 0, protein: 98, carbs: 200, fat: 44),
                                             goals: goals, locale: locale)
        XCTAssertFalse(readouts[0].isOverGoal)
        XCTAssertTrue(readouts[1].isOverGoal)
        XCTAssertFalse(readouts[2].isOverGoal)
    }

    func testGramsAreRoundedNotTruncated() {
        let readouts = MacroFormatter.macros(totals(kcal: 0, protein: 97.6, carbs: 0, fat: 0),
                                             goals: goals, locale: locale)
        XCTAssertEqual(readouts[0].text, "P 98/160")
    }
}
```

Create `apple/LiftKit/Tests/LiftKitTests/WatchRouteTests.swift`:

```swift
import XCTest
@testable import LiftKit

final class WatchRouteTests: XCTestCase {

    func testFoodLogURLParses() {
        XCTAssertEqual(WatchRoute(url: URL(string: "liftwatch://log")!), .foodLog)
    }

    func testAnotherSchemeIsRejected() {
        XCTAssertNil(WatchRoute(url: URL(string: "https://log")!))
    }

    func testUnknownRouteIsRejected() {
        XCTAssertNil(WatchRoute(url: URL(string: "liftwatch://nowhere")!))
    }

    func testRouteRoundTripsThroughItsURL() {
        XCTAssertEqual(WatchRoute(url: WatchRoute.foodLog.url), .foodLog)
    }
}
```

- [ ] **Step 2: Run both to verify they fail**

Run: `swift test --package-path LiftKit --filter "MacroFormatterTests|WatchRouteTests"`
Expected: FAIL to compile, `cannot find 'MacroFormatter' in scope` and `cannot find 'WatchRoute' in scope`.
Paste the actual output.

- [ ] **Step 3: Write the formatter**

Create `apple/LiftKit/Sources/LiftKit/MacroFormatter.swift`:

```swift
import Foundation

/// One value on the face, already formatted, plus whether it has passed its
/// goal. The view decides how "over" looks; this type decides what is over.
public struct Readout: Equatable, Sendable {
    public var text: String
    public var isOverGoal: Bool

    public init(text: String, isOverGoal: Bool) {
        self.text = text
        self.isOverGoal = isOverGoal
    }
}

public enum MacroFormatter {

    public static func calories(_ totals: NutritionTotals, goals: Goals,
                                locale: Locale = .current) -> Readout {
        Readout(text: "\(number(totals.kcal, locale)) / \(number(goals.calories, locale)) kcal",
                isOverGoal: totals.kcal > goals.calories)
    }

    /// Always exactly three, in protein/carbs/fat order. The view lays them
    /// out positionally, so the count and the order are part of the contract.
    public static func macros(_ totals: NutritionTotals, goals: Goals,
                              locale: Locale = .current) -> [Readout] {
        [("P", totals.protein, goals.protein),
         ("C", totals.carbs, goals.carbs),
         ("F", totals.fat, goals.fat)].map { label, value, goal in
            Readout(text: "\(label) \(number(value, locale))/\(number(goal, locale))",
                    isOverGoal: value > goal)
        }
    }

    private static func number(_ value: Double, _ locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value.rounded()))
            ?? String(Int(value.rounded()))
    }
}
```

- [ ] **Step 4: Write the route**

Create `apple/LiftKit/Sources/LiftKit/WatchRoute.swift`:

```swift
import Foundation

/// Where a complication tap lands. In LiftKit rather than the app target so
/// the widget extension and the app agree on one spelling of the URL, and so
/// the parsing is testable without a simulator.
public enum WatchRoute: String, Hashable, Sendable, CaseIterable {
    case foodLog = "log"

    public static let scheme = "liftwatch"

    /// `liftwatch://log` -> `.foodLog`. Anything else is nil: an unrecognised
    /// link opens the app on whatever it was already showing rather than
    /// navigating somewhere arbitrary.
    public init?(url: URL) {
        guard url.scheme == WatchRoute.scheme else { return nil }
        let target = url.host() ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let route = WatchRoute(rawValue: target) else { return nil }
        self = route
    }

    public var url: URL {
        // Force-unwrapped against a compile-time literal and a raw value that
        // is percent-safe by construction; `testRouteRoundTripsThroughItsURL`
        // is the guard if either ever changes.
        URL(string: "\(WatchRoute.scheme)://\(rawValue)")!
    }
}
```

- [ ] **Step 5: Run both tests to verify they pass**

Run: `swift test --package-path LiftKit --filter "MacroFormatterTests|WatchRouteTests"`
Expected: PASS, 11 tests.

- [ ] **Step 6: Add the App Group to the app target**

In `apple/project.yml`, under the `LiftWatch` target's `entitlements.properties`, add the group alongside the existing HealthKit keys:

```yaml
    entitlements:
      path: Config/LiftWatch.entitlements
      properties:
        com.apple.developer.healthkit: true
        com.apple.developer.healthkit.access: []
        com.apple.security.application-groups:
          - group.com.dugcanlift.watch
```

And add the extension as an embedded dependency, alongside the existing LiftKit package dependency:

```yaml
    dependencies:
      - package: LiftKit
        product: LiftKit
      - target: LiftWatchWidgets
        embed: true
```

- [ ] **Step 7: Add the extension target**

In `apple/project.yml`, after the `LiftWatch` target block, add:

```yaml
  LiftWatchWidgets:
    # WidgetKit extension: complications only. No WatchConnectivity, no
    # HealthKit authorization prompts — an extension cannot present one.
    type: app-extension
    platform: watchOS
    sources:
      - path: LiftWatchWidgets
    dependencies:
      - package: LiftKit
        product: LiftKit
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.dugcanlift.watch.widgets
        PRODUCT_NAME: LiftWatchWidgets
        GENERATE_INFOPLIST_FILE: NO
        TARGETED_DEVICE_FAMILY: "4"
        SKIP_INSTALL: NO
    info:
      path: Config/LiftWatchWidgets-Info.plist
      properties:
        CFBundleDisplayName: LIFT
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        NSExtension:
          NSExtensionPointIdentifier: com.apple.widgetkit-extension
        # Required for the steps complication's HealthKit read in Task 5.
        # Declared here as well as in the app because the extension is the
        # process that runs the query.
        NSHealthShareUsageDescription: >-
          LIFT shows today's step count on your watch face.
    entitlements:
      path: Config/LiftWatchWidgets.entitlements
      properties:
        com.apple.developer.healthkit: true
        com.apple.developer.healthkit.access: []
        com.apple.security.application-groups:
          - group.com.dugcanlift.watch
```

- [ ] **Step 8: Write the widget bundle and the complication**

Create `apple/LiftWatchWidgets/LiftWatchWidgets.swift`:

```swift
import SwiftUI
import WidgetKit

@main
struct LiftWatchWidgets: WidgetBundle {
    var body: some Widget {
        LiftMacrosWidget()
    }
}
```

Create `apple/LiftWatchWidgets/MacrosComplication.swift`:

```swift
import LiftKit
import SwiftUI
import WidgetKit

struct MacroEntry: TimelineEntry {
    let date: Date
    let totals: NutritionTotals
    let goals: Goals
}

struct MacroProvider: TimelineProvider {

    func placeholder(in context: Context) -> MacroEntry {
        MacroEntry(date: .now,
                   totals: NutritionTotals(kcal: 1420, protein: 98, carbs: 142, fat: 44),
                   goals: .fallback)
    }

    func getSnapshot(in context: Context, completion: @escaping (MacroEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MacroEntry>) -> Void) {
        // One entry, refreshed at the next local midnight. The app calls
        // `reloadTimelines` on every food log, so this schedule is only the
        // backstop that rolls the face over to a new day if the app is never
        // opened — the same shape as LIFT iOS's `TodayWidget`.
        completion(Timeline(entries: [current()], policy: .after(nextLocalMidnight())))
    }

    private func current() -> MacroEntry {
        let defaults = SharedDefaults.group
        let log = StandaloneFoodLog(defaults: defaults)
        return MacroEntry(date: .now,
                          totals: TodayTotals.totals(from: log.entries),
                          goals: GoalStore(defaults: defaults).goals)
    }

    /// Calendar arithmetic, not `.now + 86_400`: a day's worth of seconds
    /// lands an hour early or late across a DST change, and that is the one
    /// night of the year the rollover has to be right.
    private func nextLocalMidnight() -> Date {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: 1, to: startOfToday)
            ?? Date().addingTimeInterval(3600)
    }
}

struct MacroComplicationView: View {
    let entry: MacroEntry

    var body: some View {
        let calories = MacroFormatter.calories(entry.totals, goals: entry.goals)
        let macros = MacroFormatter.macros(entry.totals, goals: entry.goals)

        VStack(alignment: .leading, spacing: 1) {
            Text(calories.text)
                .font(.headline)
                .foregroundStyle(calories.isOverGoal ? Color.red : Color.primary)
            HStack(spacing: 6) {
                line(macros[0])
                line(macros[1])
            }
            line(macros[2])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(WatchRoute.foodLog.url)
        .containerBackground(.clear, for: .widget)
    }

    private func line(_ readout: Readout) -> some View {
        Text(readout.text)
            .font(.caption2)
            .foregroundStyle(readout.isOverGoal ? Color.red : Color.secondary)
    }
}

struct LiftMacrosWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LiftMacros", provider: MacroProvider()) { entry in
            MacroComplicationView(entry: entry)
        }
        .configurationDisplayName("Macros")
        .description("Calories and macros against today's goals.")
        .supportedFamilies([.accessoryRectangular])
    }
}
```

Note on `macros[0..2]`: `MacroFormatter.macros` returns exactly three readouts in a fixed order, asserted by `testMacrosAreAlwaysThreeInProteinCarbsFatOrder`.

Note on privacy: these values are deliberately **not** marked `.privacySensitive()`. Redacting them when the wrist drops would defeat the glanceability the face exists for.

- [ ] **Step 9: Reload the complication when food is logged**

In `apple/LiftWatch/WorkoutSessionModel.swift`, add `import WidgetKit` at the top, then extend `recordLocally`:

```swift
    func recordLocally(food: WatchFood, grams: Double, meal: FoodLogMeal, loggedAt: Date = .now) {
        foodLog.append(LoggedFood(food: food, grams: grams, meal: meal, loggedAt: loggedAt))
        // The complication's only path to being current. Without this the
        // face shows stale macros until the next scheduled refresh, which the
        // platform meters in minutes to tens of minutes.
        WidgetCenter.shared.reloadTimelines(ofKind: "LiftMacros")
    }
```

- [ ] **Step 10: Regenerate and build**

Run: `xcodegen generate`
Expected: `Created project at .../LiftWatch.xcodeproj`

Run: `xcodebuild -project LiftWatch.xcodeproj -scheme LiftWatch -destination 'generic/platform=watchOS' build`
Expected: BUILD SUCCEEDED, with `LiftWatchWidgets.appex` in the build log.

- [ ] **Step 11: Commit**

```bash
git add apple/project.yml apple/LiftWatch.xcodeproj apple/Config apple/LiftWatchWidgets apple/LiftKit/Sources/LiftKit/MacroFormatter.swift apple/LiftKit/Sources/LiftKit/WatchRoute.swift apple/LiftKit/Tests/LiftKitTests/MacroFormatterTests.swift apple/LiftKit/Tests/LiftKitTests/WatchRouteTests.swift apple/LiftWatch/WorkoutSessionModel.swift
git commit -m "feat(watch): add the macros complication and its widget extension"
```

---

### Task 5: The steps complication

**Files:**
- Create: `apple/LiftKit/Sources/LiftKit/StepsFormatter.swift`
- Create: `apple/LiftWatchShared/StepsReader.swift` (compiled into both targets)
- Create: `apple/LiftWatchWidgets/StepsComplication.swift`
- Create: `apple/LiftWatchShared/StepsAuthorization.swift`
- Modify: `apple/project.yml` (add `LiftWatchShared` to both targets' sources)
- Modify: `apple/LiftWatch/RootView.swift:8-22` (request authorization on appear)
- Modify: `apple/LiftWatchWidgets/LiftWatchWidgets.swift` (register the widget)
- Test: `apple/LiftKit/Tests/LiftKitTests/StepsFormatterTests.swift`

**Interfaces:**
- Consumes: `Goals`, `GoalStore`, `SharedDefaults.group`
- Produces: `StepsState.unauthorized`, `StepsState.count(Int)`, `StepsReadout(text:fraction:)`, `StepsFormatter.readout(_:goal:locale:)`, `StepsReader.todaysSteps(now:calendar:) async -> StepsState`, `StepsAuthorization.requestedKey`, `StepsAuthorization.request(defaults:) async`, widget kind `"LiftSteps"`

- [ ] **Step 1: Write the failing test**

Create `apple/LiftKit/Tests/LiftKitTests/StepsFormatterTests.swift`:

```swift
import XCTest
@testable import LiftKit

final class StepsFormatterTests: XCTestCase {

    private let locale = Locale(identifier: "en_US_POSIX")

    func testUnauthorizedShowsADashAndFillsNothing() {
        // Never "0". A confident zero beside a moving Activity ring reads as
        // a broken app rather than a permission that was never granted.
        let readout = StepsFormatter.readout(.unauthorized, goal: 10_000, locale: locale)
        XCTAssertEqual(readout.text, "—")
        XCTAssertNil(readout.fraction)
    }

    func testThousandsAreAbbreviatedForASmallSlot() {
        let readout = StepsFormatter.readout(.count(8432), goal: 10_000, locale: locale)
        XCTAssertEqual(readout.text, "8.4K")
        XCTAssertEqual(readout.fraction!, 0.8432, accuracy: 0.0001)
    }

    func testUnderAThousandShowsExactly() {
        XCTAssertEqual(StepsFormatter.readout(.count(742), goal: 10_000, locale: locale).text, "742")
    }

    func testFiveDigitsDropTheDecimalAndRoundDown() {
        // 12,500 is "12K", never "13K": a step count must not claim steps
        // that were not taken.
        XCTAssertEqual(StepsFormatter.readout(.count(12_500), goal: 10_000, locale: locale).text, "12K")
    }

    func testGaugeClampsAtTheGoal() {
        XCTAssertEqual(StepsFormatter.readout(.count(15_000), goal: 10_000, locale: locale).fraction, 1)
    }

    func testZeroGoalFillsNothingRatherThanDividingByZero() {
        XCTAssertNil(StepsFormatter.readout(.count(500), goal: 0, locale: locale).fraction)
    }

    func testZeroStepsAfterAuthorizationIsAHonestZero() {
        let readout = StepsFormatter.readout(.count(0), goal: 10_000, locale: locale)
        XCTAssertEqual(readout.text, "0")
        XCTAssertEqual(readout.fraction, 0)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path LiftKit --filter StepsFormatterTests`
Expected: FAIL to compile, `cannot find 'StepsFormatter' in scope`.
Paste the actual output.

- [ ] **Step 3: Write the formatter**

Create `apple/LiftKit/Sources/LiftKit/StepsFormatter.swift`:

```swift
import Foundation

/// What the widget knows about today's steps.
///
/// `unauthorized` is not "zero steps". HealthKit never reveals whether a
/// *read* was authorized — a denied read returns an empty result,
/// indistinguishable from a day with no steps — so the app records that it
/// asked and the complication treats "never asked" as this case.
public enum StepsState: Equatable, Sendable {
    case unauthorized
    case count(Int)
}

public struct StepsReadout: Equatable, Sendable {
    public var text: String
    /// 0...1 for the gauge, or nil when there is nothing truthful to fill it
    /// with — an unauthorized read, or a goal of zero.
    public var fraction: Double?

    public init(text: String, fraction: Double?) {
        self.text = text
        self.fraction = fraction
    }
}

public enum StepsFormatter {

    public static func readout(_ state: StepsState, goal: Double,
                               locale: Locale = .current) -> StepsReadout {
        switch state {
        case .unauthorized:
            return StepsReadout(text: "—", fraction: nil)
        case .count(let steps):
            let fraction = goal > 0 ? min(Double(steps) / goal, 1) : nil
            return StepsReadout(text: abbreviated(steps, locale), fraction: fraction)
        }
    }

    /// "8.4K" rather than "8,432": the circular slot is about 30pt across.
    /// Rounds **down** throughout — a step counter must never claim steps
    /// that were not taken.
    private static func abbreviated(_ steps: Int, _ locale: Locale) -> String {
        guard steps >= 1000 else { return String(steps) }
        let thousands = Double(steps) / 1000
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.roundingMode = .down
        formatter.maximumFractionDigits = thousands < 10 ? 1 : 0
        let number = formatter.string(from: NSNumber(value: thousands))
            ?? String(Int(thousands))
        return number + "K"
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path LiftKit --filter StepsFormatterTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Write the HealthKit reader, shared by both targets**

Create `apple/LiftWatchShared/StepsReader.swift`:

```swift
import Foundation
import HealthKit
import LiftKit

/// Today's step count, read on the watch itself.
///
/// Compiled into both the app and the widget extension. Authorization is
/// never requested here: an app extension cannot present an authorization
/// sheet, so a widget that asked would fail silently and forever. The app
/// asks — see `StepsAuthorization` — and this reads.
struct StepsReader {
    private let store = HKHealthStore()

    static var stepType: HKQuantityType { HKQuantityType(.stepCount) }

    func todaysSteps(now: Date = Date(),
                     calendar: Calendar = .current,
                     defaults: UserDefaults = SharedDefaults.group) async -> StepsState {
        guard HKHealthStore.isHealthDataAvailable(),
              defaults.bool(forKey: StepsAuthorization.requestedKey) else {
            return .unauthorized
        }

        // Local midnight, by Calendar. Same rule as the food totals.
        let start = calendar.startOfDay(for: now)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: Self.stepType,
                                          quantitySamplePredicate: predicate,
                                          options: .cumulativeSum) { _, statistics, _ in
                guard let sum = statistics?.sumQuantity() else {
                    // No samples today, or a read the user denied — HealthKit
                    // does not distinguish the two. Reported as a real zero
                    // because authorization was at least requested.
                    continuation.resume(returning: .count(0))
                    return
                }
                continuation.resume(returning: .count(Int(sum.doubleValue(for: .count()))))
            }
            store.execute(query)
        }
    }
}
```

Create `apple/LiftWatchShared/StepsAuthorization.swift` — in the **shared**
folder, not the app folder: `StepsReader` reads `requestedKey` and is compiled
into both targets, so a type it references that lives only in the app target
would not compile in the extension. The extension simply never calls
`request()`.

```swift
import Foundation
import HealthKit
import LiftKit

enum StepsAuthorization {
    /// Lives in the App Group suite so the extension can read it.
    static let requestedKey = "com.dugcanlift.lift.stepsAuthorizationRequested"

    /// Requests read access to step count, and records that it asked.
    ///
    /// The flag exists because HealthKit deliberately never reveals whether a
    /// read was authorized. Without it the complication cannot tell "you have
    /// not been asked yet" from "you walked nothing today", and would show a
    /// confident `0` next to a moving Activity ring the first time the face
    /// was configured.
    ///
    /// Note this is a second prompt, separate from the share authorization
    /// `HealthKitExporter` requests when exporting a run. Combining them would
    /// mean asking for write access before the user has recorded anything.
    static func request(defaults: UserDefaults = SharedDefaults.group) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        do {
            try await HKHealthStore().requestAuthorization(toShare: [],
                                                           read: [HKQuantityType(.stepCount)])
            defaults.set(true, forKey: requestedKey)
        } catch {
            // Flag left unset: the complication keeps showing its
            // unauthorized state rather than a zero it cannot justify.
        }
    }
}
```

- [ ] **Step 6: Write the complication**

Create `apple/LiftWatchWidgets/StepsComplication.swift`:

```swift
import LiftKit
import SwiftUI
import WidgetKit

struct StepsEntry: TimelineEntry {
    let date: Date
    let readout: StepsReadout
}

struct StepsProvider: TimelineProvider {

    func placeholder(in context: Context) -> StepsEntry {
        StepsEntry(date: .now,
                   readout: StepsFormatter.readout(.count(8432), goal: Goals.fallback.steps))
    }

    func getSnapshot(in context: Context, completion: @escaping (StepsEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task { completion(await current()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StepsEntry>) -> Void) {
        Task {
            // A single entry, refreshed in half an hour. Future entries are
            // not an option here: a step count cannot be predicted, so
            // pre-built entries would render a stale number as if it were
            // current. The lag is the platform's refresh budget, not a bug.
            let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date())
                ?? Date().addingTimeInterval(1800)
            completion(Timeline(entries: [await current()], policy: .after(next)))
        }
    }

    private func current() async -> StepsEntry {
        let goal = GoalStore(defaults: SharedDefaults.group).goals.steps
        let state = await StepsReader().todaysSteps()
        return StepsEntry(date: .now, readout: StepsFormatter.readout(state, goal: goal))
    }
}

struct StepsComplicationView: View {
    let entry: StepsEntry

    var body: some View {
        Gauge(value: entry.readout.fraction ?? 0) {
            Text("Steps")
        } currentValueLabel: {
            Text(entry.readout.text)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetURL(WatchRoute.foodLog.url)
        .containerBackground(.clear, for: .widget)
    }
}

struct LiftStepsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LiftSteps", provider: StepsProvider()) { entry in
            StepsComplicationView(entry: entry)
        }
        .configurationDisplayName("Steps")
        .description("Today's steps against your goal.")
        // Both families deliberately. Which one Infograph Modular's top-left
        // slot accepts is unverified; device testing decides, and the loser
        // can be deleted then.
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}
```

Register it in `apple/LiftWatchWidgets/LiftWatchWidgets.swift`:

```swift
@main
struct LiftWatchWidgets: WidgetBundle {
    var body: some Widget {
        LiftMacrosWidget()
        LiftStepsWidget()
    }
}
```

- [ ] **Step 7: Request authorization from the app**

In `apple/LiftWatch/RootView.swift`, attach a `.task` to the `NavigationStack`:

```swift
        NavigationStack {
            // ... existing body unchanged
        }
        .task { await StepsAuthorization.request() }
```

- [ ] **Step 8: Add the shared folder to both targets**

In `apple/project.yml`, add to the `LiftWatch` target's `sources`:

```yaml
    sources:
      - path: LiftWatch
      - path: LiftWatchShared
```

and to the `LiftWatchWidgets` target's `sources`:

```yaml
    sources:
      - path: LiftWatchWidgets
      - path: LiftWatchShared
```

- [ ] **Step 9: Regenerate and build**

Run: `xcodegen generate`
Run: `xcodebuild -project LiftWatch.xcodeproj -scheme LiftWatch -destination 'generic/platform=watchOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 10: Commit**

```bash
git add apple/project.yml apple/LiftWatch.xcodeproj apple/LiftWatchShared apple/LiftWatchWidgets apple/LiftWatch/RootView.swift apple/LiftKit/Sources/LiftKit/StepsFormatter.swift apple/LiftKit/Tests/LiftKitTests/StepsFormatterTests.swift
git commit -m "feat(watch): add the steps complication and its HealthKit read"
```

---

### Task 6: Goals screen

**Files:**
- Create: `apple/LiftWatch/GoalsView.swift`
- Modify: `apple/LiftWatch/RootView.swift:52-61` (add the navigation link)

**Interfaces:**
- Consumes: `Goals`, `GoalStore`, `SharedDefaults.group`
- Produces: `GoalsView`

- [ ] **Step 1: Write the screen**

Create `apple/LiftWatch/GoalsView.swift`:

```swift
import LiftKit
import SwiftUI
import WidgetKit

/// The watch's own copy of the targets the complications measure against.
///
/// Exists because LIFT iOS keeps goals in `UserDefaults.standard` on the
/// phone, which a watch with no companion app cannot reach. Steppers rather
/// than text entry: the Digital Crown drives them, and there is no keyboard
/// worth using here.
struct GoalsView: View {
    @State private var goals: Goals
    private let store: GoalStore

    init(store: GoalStore = GoalStore(defaults: SharedDefaults.group)) {
        self.store = store
        _goals = State(initialValue: store.goals)
    }

    var body: some View {
        List {
            stepper("Calories", value: $goals.calories, step: 50, unit: "kcal")
            stepper("Protein", value: $goals.protein, step: 5, unit: "g")
            stepper("Carbs", value: $goals.carbs, step: 5, unit: "g")
            stepper("Fat", value: $goals.fat, step: 5, unit: "g")
            stepper("Steps", value: $goals.steps, step: 500, unit: "")
        }
        .navigationTitle("Goals")
        .onDisappear {
            store.save(goals)
            // Both kinds: every complication on the face measures against
            // these numbers.
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func stepper(_ label: String, value: Binding<Double>,
                         step: Double, unit: String) -> some View {
        Stepper(value: value, in: 0...30_000, step: step) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(unit.isEmpty ? String(Int(value.wrappedValue))
                                  : "\(Int(value.wrappedValue)) \(unit)")
            }
        }
    }
}
```

- [ ] **Step 2: Link it from the start screen**

In `apple/LiftWatch/RootView.swift`, inside `StartWorkoutView`'s last `Section`, after the existing "Export Foods" link:

```swift
                NavigationLink("Goals") {
                    GoalsView()
                }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project LiftWatch.xcodeproj -scheme LiftWatch -destination 'generic/platform=watchOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add apple/LiftWatch/GoalsView.swift apple/LiftWatch/RootView.swift
git commit -m "feat(watch): add a goals screen for the complications to measure against"
```

---

### Task 7: The deep link

**Files:**
- Modify: `apple/LiftWatch/RootView.swift:8-22` (routed navigation stack)
- Modify: `apple/project.yml` (register the URL scheme)

**Interfaces:**
- Consumes: `WatchRoute` (Task 4)
- Produces: nothing later tasks depend on

- [ ] **Step 1: Register the URL scheme**

In `apple/project.yml`, under the `LiftWatch` target's `info.properties`, add:

```yaml
        # The complications' `widgetURL`. Without a registered scheme the tap
        # opens the app at whatever it was last showing and `onOpenURL` never
        # fires.
        CFBundleURLTypes:
          - CFBundleURLName: com.dugcanlift.watch
            CFBundleURLSchemes:
              - liftwatch
```

- [ ] **Step 2: Route the navigation stack**

Replace the body of `RootView` in `apple/LiftWatch/RootView.swift`:

```swift
struct RootView: View {
    @EnvironmentObject private var session: WorkoutSessionModel
    @EnvironmentObject private var outdoorRecorder: OutdoorActivityRecorder
    @State private var path: [WatchRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                // An in-progress outdoor recording takes priority: once
                // `start(type:)` is called, `activity` stays non-nil (even right
                // after `finish()`, until `OutdoorActivityView` resets it) so
                // this is the state that should own the screen.
                if outdoorRecorder.activity != nil {
                    OutdoorActivityView()
                } else if session.draft == nil {
                    StartWorkoutView()
                } else {
                    WorkoutView()
                }
            }
            .navigationDestination(for: WatchRoute.self) { route in
                switch route {
                case .foodLog:
                    RecentFoodsListView()
                }
            }
        }
        .task { await StepsAuthorization.request() }
        .onOpenURL { url in
            guard let route = WatchRoute(url: url) else { return }
            // Pushed, never substituted. A live workout or an active run keeps
            // owning the root of the stack and keeps recording; dismissing the
            // log returns to it. Replacing the root here would leave a running
            // recording behind a screen the user has to find their way out of.
            path = [route]
        }
    }
}
```

- [ ] **Step 3: Regenerate and build**

Run: `xcodegen generate`
Run: `xcodebuild -project LiftWatch.xcodeproj -scheme LiftWatch -destination 'generic/platform=watchOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add apple/project.yml apple/LiftWatch.xcodeproj apple/Config apple/LiftWatch/RootView.swift
git commit -m "feat(watch): open the food log from a complication tap"
```

---

### Task 8: Device checklist and the face-sharing guide

**Files:**
- Create: `docs/WATCH-FACE.md`
- Modify: `docs/DEVICE-TESTING.md` (append a section)

**Interfaces:**
- Consumes: everything above
- Produces: documentation only

- [ ] **Step 1: Write the face-sharing guide**

Create `docs/WATCH-FACE.md`:

```markdown
# The LIFT watch face

watchOS has no third-party watch faces. What LIFT ships is two complications
that sit in Apple's **Infograph Modular** face, plus a shareable copy of that
face once it is configured.

## Configuring it

1. Install the watch app. The complications appear once it has launched once.
2. On the watch, long-press the face, tap Edit, and pick Infograph Modular.
3. Set the slots:
   - top-left circular — LIFT, Steps
   - middle rectangular — LIFT, Macros
   - bottom-left circular — Weather
   - bottom-right circular — Heart Rate
4. Open LIFT, tap Goals, and set the five targets. Until you do, the
   complications measure against LIFT iOS's defaults (1748 kcal, 160 g
   protein, 167 g carbs, 49 g fat, 10,000 steps).
5. Grant the Health prompt on first launch, or the steps slot shows a dash.

## Sharing it

Long-press the face, tap Share, and send it as a `.watchface`.

The LIFT slots only fill for someone who already has the watch app installed.
Face Sharing points recipients at an App Store listing that does not exist —
LIFT is sideload-only for now — so a shared face reaches anyone else with two
empty slots. This is a limitation of distribution, not of the face.

## What is live and what is not

The time, date, heart rate and weather are Apple's and update continuously.
The macros are current the moment you log food on the watch, because the app
reloads that complication on every write. Steps are read from HealthKit on a
metered refresh and lag by minutes — they will visibly disagree with the
Activity ring beside them. On Always-On Display, complications redraw about
once a minute and render dimmed.
```

- [ ] **Step 2: Append the device checklist**

Add to the end of `docs/DEVICE-TESTING.md`:

```markdown
## Watch face complications

None of this can be verified in the simulator's watch face editor alone —
complication layout, HealthKit reads and deep links all need hardware.

- [ ] Both complications appear in the Infograph Modular editor's slot picker.
- [ ] **Which family the top-left slot accepts** — `LiftSteps` declares both
      `.accessoryCircular` and `.accessoryCorner` because this is unverified.
      Note which one the face actually uses and delete the other.
- [ ] The macros slot renders three lines without truncation at 41, 45 and
      49 mm. The longest realistic string is a four-digit calorie total
      against a four-digit goal.
- [ ] Log a food on the watch; the macros complication updates without
      reopening the app.
- [ ] Set a goal below today's intake; the offending number turns red and the
      others do not.
- [ ] Check the red state on a tinted face — the numbers must still read
      correctly when the colour is washed out.
- [ ] Before granting the Health prompt, the steps slot shows a dash, never a
      zero.
- [ ] After granting it, the steps slot shows a count within a few minutes.
- [ ] Tap the macros complication from the face: LIFT opens on the food log,
      not on its start screen.
- [ ] **Start a run, drop the wrist, then tap the macros complication.** The
      food log opens over the run; dismissing it returns to a run that is
      still recording.
- [ ] Log food on the watch, then check the export screen still lists every
      entry — the App Group migration must not have lost any.
- [ ] Install over a build that predates the App Group and confirm previously
      logged food is still on the export screen.
```

- [ ] **Step 3: Commit**

```bash
git add docs/WATCH-FACE.md docs/DEVICE-TESTING.md
git commit -m "docs: watch face setup, sharing limits and the device checklist"
```

---

## Notes for the executor

**The two things most likely wrong in this plan:**

1. `Gauge` with `.accessoryCircularCapacity` inside an `.accessoryCorner`
   family may not render as intended — corner complications have their own
   layout rules. If the corner rendering is wrong, fix the view rather than
   dropping the family until device testing says which family the slot wants.
2. `HKStatisticsQuery` inside `withCheckedContinuation` must resume exactly
   once. The error path and the success path are mutually exclusive as
   written, but verify under a denied authorization on device.

**Deferred, by design:** the `WCSession` transport question (see the spec's
closing section), the Wear OS face, and App Store submission. Nothing in this
plan depends on any of them.
