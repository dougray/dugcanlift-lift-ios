# LIFT watch face: complications and portal

Date: 2026-09-13
Status: design, approved in chat, not yet planned
Platform: watchOS first. Wear OS is a later, separate spec.

## Goal

Give the Apple Watch face a glanceable LIFT dashboard and a one-tap portal
into the watch app's food log.

Two things follow from that framing, and they pull in opposite directions:
the face must be readable without interaction, and it must be the fastest
way to start an interaction. The rectangular slot serves both — it is the
largest readable surface on the face and its largest tap target.

## Non-goals

- A custom watch face. watchOS does not have them. This spec builds
  complications that sit in Apple's Infograph Modular face.
- The phone to watch transport. See "Deferred: the transport question".
- The Wear OS watch face, where a literal custom face *is* buildable.
- App Store submission. Consistent with the project's standing decision to
  stay on sideload/free-signing for beta.

## Constraints this design accepts

**Third-party complications are not live.** They render from a timeline
built in advance, refreshed under a metered daily budget. The liveness
contract this face can actually honour:

| Slot | Source | Liveness |
| --- | --- | --- |
| Time, date | System | Live |
| BPM | Apple Heart Rate | Live |
| Weather | Apple Weather | Apple's own refresh |
| Macros | LIFT | Current as of your last watch log; the app forces a reload on write |
| Steps | LIFT via HealthKit | Lags by minutes; will visibly disagree with the Activity ring beside it |

On Always-On Display, complications redraw roughly once a minute and render
dimmed. Reading current macros at a glance works. Watching a number tick
does not.

**The watch app is standalone.** `WKWatchOnly: YES`, bundle
`com.dugcanlift.watch`, no iOS counterpart in this project. Every number on
this face therefore comes from the watch itself.

## Face layout

Apple's Infograph Modular, configured by hand and exported via Face Sharing.

| Slot | Content | Provider |
| --- | --- | --- |
| Top-left circular | Steps / goal, as a gauge | **LIFT** |
| Top-right | Day, date, time | System |
| Middle rectangular | Calories and macros vs goal | **LIFT** |
| Bottom-left circular | Weather | Apple |
| Bottom-right circular | BPM | Apple |

The middle slot renders three lines:

```
1,420 / 2,300 kcal
P 98/160  C 142/167
F 44/49
```

Fiber is tracked in LIFT iOS but omitted here; three lines is the budget and
fiber is the least glanceable of the four.

## Components

### 1. `LiftWatchWidgets` extension target

New app-extension target in `apple/project.yml`. Bundle
`com.dugcanlift.watch.widgets`, watchOS 10, depends on the existing LiftKit
package. Two `StaticConfiguration` widgets:

- `LiftMacros` — `.accessoryRectangular`
- `LiftSteps` — `.accessoryCircular` **and** `.accessoryCorner`

Supporting both families on `LiftSteps` is deliberate. Which one Infograph
Modular's top-left slot accepts has not been verified on hardware, and
declaring both costs one line and removes the guess. Confirm on device and
drop the unused family afterwards if it is dead weight.

### 2. App Group and the `StandaloneFoodLog` migration

A widget extension is a separate process with its own container. The watch
app currently holds no group entitlement — `LiftWatch.entitlements` declares
HealthKit and nothing else — so the extension cannot see anything the app
has written.

Add `group.com.dugcanlift.watch` to both targets and point
`StandaloneFoodLog` at that suite. It already takes `defaults:` in its
initializer, so this is a call-site change rather than a rewrite.

**The migration copies forward and never deletes the `.standard` copy.**
Issue #4 was data loss in this exact store, and its own doc comment is
explicit that until a QR code is scanned this store is the only copy of the
log that exists anywhere. A migration that moves rather than copies is the
same class of defect that bug already taught this repo once. The test
asserts the source suite still holds its entries after migration.

### 3. `GoalStore`

Goals live on the phone as plain `@AppStorage` in `UserDefaults.standard`
(`goalCalories`, `goalProtein`, `goalCarbs`, `goalFat`, `goalSteps`) and are
unreachable from the watch — which is also why the existing iOS widget shows
bare numbers with no target.

New `GoalStore` in LiftKit, backed by the App Group suite, plus a Goals
screen on the watch for the five values. Defaults match the iOS defaults so
a fresh watch is not showing goals of zero:

| Goal | Default |
| --- | --- |
| Calories | 1748 |
| Protein | 160 g |
| Carbs | 167 g |
| Fat | 49 g |
| Steps | 10,000 |

If a transport ever lands, a phone snapshot overwrites this store and the
screen becomes a fallback rather than the source.

### 4. Today's totals

Fold `StandaloneFoodLog` entries whose `loggedAt` falls in today. Each
`LoggedFood` carries `WatchFood` per-100g macros and `grams`, so totals need
no reference database and no phone.

**Day boundaries are local, computed with `Calendar`, never UTC and never
by arithmetic on a timestamp.** A UTC boundary misfiles evening logs into
tomorrow, and hand-rolled 86,400-second arithmetic breaks across a DST
change. Both are tested.

### 5. Steps

`HKStatisticsQuery` over `stepCount` from local midnight.

Today `HealthKitExporter` requests share (write) types only, for outdoor
activity export. Reading steps is a new authorization, and every existing
user sees a new prompt.

Three mechanics worth writing into the plan so they are not discovered late:

- An extension cannot present an authorization prompt. The **containing
  app** requests read access; the extension only queries once that is
  granted.
- The extension needs the HealthKit entitlement of its own to query at all.
- Before authorization, the steps complication renders its unauthorized
  state, not a zero. A confident `0` next to a moving Activity ring reads as
  a broken app.

### 6. Routing: the portal

Each widget sets `widgetURL`. `LiftMacros` opens `liftwatch://log`, landing
on the food log rather than the app root — one tap instead of four.

`RootView` has no `onOpenURL` and no path state today, and the food entries
are plain `NavigationLink`s inside `StartWorkoutView`. So: `NavigationStack(path:)`,
a `Route` enum, and `onOpenURL` mapping the URL onto it.

**A deep link never interrupts a live session.** `RootView`'s root swaps
itself out by state — an in-progress outdoor recording owns the screen, then
a live workout, then the start screen. A link arriving mid-workout pushes
the log *onto* the stack above that screen; dismissing it returns to the
session, still recording. The recording is never torn down, replaced, or
navigated away from.

`LiftSteps` opens the app root. There is no steps detail screen and this
spec does not invent one.

## Refresh

- The app calls `WidgetCenter.shared.reloadTimelines(ofKind: "LiftMacros")`
  after every food log write, so the number is current the moment you back
  out of the log screen.
- Each timeline carries a backstop entry at the next **local** midnight, so
  the face rolls over to a new day even if the app is never opened. This
  mirrors the existing iOS `TodayWidget`.
- Steps refresh on a coarse periodic cadence: **one** entry holding the
  current count, with the timeline asking to be refreshed again in 30
  minutes. Not a run of pre-built future entries — a step count cannot be
  predicted, so entries stamped ahead of time would render a stale number as
  though it were current. The lag is a property of the platform's budget, not
  a bug to fix later. Tune the interval only against measured budget
  exhaustion on device, never by guessing.

## States

| State | Rendering |
| --- | --- |
| Nothing logged today | `0 / 2,300 kcal` with zeroed macros. Not an empty-state string — the goal is the useful half. |
| Over goal | The offending number turns red; numbers within goal stay neutral. |
| Goals never set | Defaults above, rendered normally. |
| Steps unauthorized | Unauthorized state, never `0`. |

Red is the only colour carrying meaning, and tinted watch faces can wash it
out, so the number itself must still read correctly without the colour. No
state is communicated by colour alone.

Macro values are **not** marked `.privacySensitive()`. Redacting them when
the wrist drops would defeat the glanceability this face exists for. Worth
revisiting if the face is ever shared with anyone else.

## Testing

TDD. In `LiftKitTests`:

- Today's totals fold correctly across a local midnight, and across a DST
  boundary.
- Totals ignore entries outside today without deleting them.
- `GoalStore` defaults match the iOS defaults; a set value survives a round
  trip.
- The App Group migration copies entries forward **and leaves the source
  suite intact**.
- Over-goal, at-goal and zero states produce the expected formatted strings.

Manual, documented in `DEVICE-TESTING.md`:

- Both complications render without truncation at 41, 45 and 49 mm.
- Which family Infograph Modular's top-left slot actually accepts.
- A deep link tapped mid-run returns to a still-recording run.
- The HealthKit prompt appears on app launch, not from the extension.

## Distribution

Configure the face on device, then export it through Face Sharing as a
`.watchface`. Steps documented in `docs/`; no code.

The shared face only fills the LIFT slots for someone who already has the
app installed, and Face Sharing points at an App Store listing that does not
exist. For Doug and sideloaded testers this works. As a public artifact it
does not, until LIFT ships.

## Deferred: the transport question

LIFT iOS and LiftWatch are very likely not `WCSession` peers.
LiftWatch is `WKWatchOnly: YES` with bundle `com.dugcanlift.watch`; lift-ios
ships three iOS targets and embeds no watch app. `WCSession` connects an iOS
app to its own companion watch app, and a watch-only app has no counterpart,
so `transferUserInfo` queues into nothing — the silent-success behaviour
`ARCHITECTURE.md` already documents. Both sides implement full delegates and
no device test verifies a delivery.

This is unproven from source alone, and out of scope here. It deserves its
own spike, because the consequence is larger than this face: if true, the
phone to watch food snapshot has never worked on device.

This design does not depend on the answer. Every number on the face is
computed on the watch.
