# LIFT for Apple Watch

The watch app is LIFT for iPhone's companion. It is built by this repo's
`project.yml` as the `LiftWatch` target and ships inside the iPhone app, at
`Lift.app/Watch/LIFT.app`, under the iPhone app's version. It lived in
`dugcanlift-lift-watch` as a standalone `WKWatchOnly` app (`com.dugcanlift.watch`)
until 2026-09 and moved here with its history (`git blame` on a file here
follows it back through the subtree merge).

- `LiftWatch/` — the watchOS app target: SwiftUI views plus
  `PhoneSyncTransport`, the only file that touches `WatchConnectivity`, and
  the app's own `PrivacyInfo.xcprivacy`.
- `LiftWatchKit/` — Swift package (package `LiftWatchKit`; it is not named
  `LiftKit` because dugcanlift-kit's package already is, and Xcode would take
  one for an override of the other). Two products:
  - `LiftSync` — the WatchConnectivity wire types: `SyncEnvelope`,
    `FoodLogPayload`, `WorkoutPlan` and its parts, `SessionHeartRate`,
    `RecentFoodsSnapshot`, `WatchFood`. **Both apps compile this one copy**:
    the iPhone app links `LiftSync` alone, the watch gets it through `LiftKit`.
  - `LiftKit` — the watch's domain: `WorkoutDraft`, revision-based
    reconciliation (`WorkoutStore`), the offline edit queue (`SyncOutbox`),
    `RestTimer`, the guided session (`GuidedSession`, `PlanDisplay`), the
    food library, the standalone food log and its QR export, outdoor
    activities, and `PlanRequestGate`.

  Unit tested with `swift test`, no simulator (`make watch-test`).
- `contracts/` — `workout-sync.schema.json` and
  `recent-foods-snapshot.schema.json`, the wire contract between the two apps.
  `LiftSyncTests/SchemaConformanceTests` reads them from here and checks the
  Swift types against them in both directions. Wear OS has no phone transport
  and never used them; if it ever gets one, copy them and pin the copy.

## Building

From the repo root:

```sh
make watch-test     # the package's tests (also part of make test)
make watch          # build the LiftWatch scheme for the watch simulator
make watch-run      # run LIFT on the iPhone simulator and the watch paired with it
make device-build   # a device build of the iPhone app, watch app embedded
make watch-device   # install that embedded watch app on the real paired watch
make signing        # which entitlements each target signs with on the free team
```

The product is `LIFT.app`, not `LiftWatch.app`: the scheme and the bundle name
differ, which is worth knowing before hand-writing an install path.

**The simulator does not install an embedded watch app by itself.** A real
iPhone's Watch app installs it on the paired watch (automatically, or from
"Available Apps"); the simulator does not, so `make watch-run` does what Xcode
does and runs `simctl install <watch> Lift.app/Watch/LIFT.app`. The watch
simulator is the one paired with `$(SIM)`: `WCSession` only connects a pair.

## Identity, signing and versions

- Bundle id `com.dugcanlift.lift.watchkitapp`, a child of the iPhone app's
  `com.dugcanlift.lift`, named in `WKCompanionAppBundleIdentifier`. Being the
  companion is what makes the two `WCSession` peers; a watch-only app with its
  own id is not, and nothing either side sent to the other ever arrived.
- `WKRunsIndependentlyOfCompanionApp` is set: the app installs and works with
  no iPhone nearby (it logs food from its own library and records runs).
- One version. The watch target sets no `MARKETING_VERSION` or
  `CURRENT_PROJECT_VERSION` of its own, and every Info.plist in the project
  reads those two settings: App Store validation rejects an embedded watch app
  whose version differs from its container's.
- Entitlements: HealthKit only. Nothing a free Personal Team cannot sign, and
  WatchConnectivity needs no entitlement. `make device-build` swaps the free-team
  entitlements onto the Lift target only (`FREE_TEAM_ENTITLEMENTS`), so the
  watch keeps its own.
- HealthKit authorization belongs to a bundle id, so the move from
  `com.dugcanlift.watch` asks for it again on first launch. Workouts already
  saved stay in Health.
- A new bundle id is a new sandbox: the old app's `UserDefaults` (its
  standalone food log above all) do not carry over. Export it by QR code from
  the old app before deleting it.

## How it talks to the phone

`SyncEnvelope` over `WCSession`, both directions, plus the recent-foods snapshot
as application context:

| What | Direction | How |
|---|---|---|
| `PLAN_REQUEST` | watch -> phone | `sendMessage` if reachable, else `transferUserInfo`; at most one per 10 s from automatic triggers (`PlanRequestGate`) |
| `PLAN_PUSHED` | phone -> watch | `sendMessage` if reachable, else `transferUserInfo`; on the phone's activation, on request, and when a coach's plan is accepted or a routine is sent from Routines |
| Recent foods | phone -> watch | `updateApplicationContext`, with per-100 g macros where the phone knows them |
| `FOOD_LOGGED` | watch -> phone | `sendMessage` if reachable, else `transferUserInfo` |
| `WORKOUT_SYNC_ACK` for a food | phone -> watch | as `PLAN_PUSHED`; takes the food out of the standalone log |
| `SESSION_FINISHED`, `WORKOUT_EDITED`, `OUTDOOR_ACTIVITY_FINISHED` | watch -> phone | `transferUserInfo` via `SyncOutbox` |

**`transferUserInfo` never arrives between simulators**, in either direction.
Apple DTS says the watchOS Simulator does not support it, and the spike's
`wcd` traces show the payload reaching the peer's daemon and being dropped
there. On a simulator pair only `sendMessage` and application context are
seen to work; the queued path needs real devices. That is why a DEBUG build
still accepts one envelope from the launch environment, delivered through the
same `receive(_:)` the transport calls:

```sh
SIMCTL_CHILD_LIFT_SYNC_ENVELOPE="$(cat plan.json)" \
  xcrun simctl launch "Apple Watch Ultra 4 (49mm)" com.dugcanlift.lift.watchkitapp
```

## Architecture

The watch may create, retain, edit and later synchronize a workout without a
live phone connection. The domain contract preserves stable workout, exercise
and set ids. A workout snapshot is revisioned; a receiver inserts an unknown id,
accepts a newer revision, ignores an older one, treats an identical revision as
idempotent, and acknowledges the accepted revision.

- `WorkoutDraft` — every mutation that changes state goes through one `commit`
  path, so exactly one thing bumps `revision`.
- `WorkoutStore.apply(_:)` — the reconciliation rule above, as a pure function
  returning `ReconcileOutcome` (`inserted` / `accepted` / `ignored` /
  `idempotent`); only a stored outcome produces an acknowledgement.
- `SyncOutbox` — queues local edits while the phone is unreachable, collapsing
  to the newest revision per workout, and clears an entry once its revision is
  acknowledged.

### The guided session

A plan is what the watch is meant to lift today; a `WorkoutDraft` is what was
actually lifted. The two never merge: training against a plan builds an
ordinary draft, so revisions, `SyncOutbox` and `SESSION_FINISHED` behave exactly
as they do for a workout typed in from nothing, and **a session with no plan is
the free-entry flow unchanged**.

- `WorkoutPlan` is the `plan` payload of `PLAN_PUSHED`. `PLAN_REQUEST` is a bare
  envelope asking for the current one. Identity is the envelope's: `workoutId`
  is the plan's id and `revision` the plan's revision, so the reconciliation
  rule covers a re-push with no new machinery.
- **Every prescribed field is optional.** `PrescribedSet.weightKg` is `Double?`
  where `DraftSet.weightKg` is a plain `Double`, because PLAN-FORMAT's
  `[null, 5]` is "five reps, you pick the weight" and a blank must never reach
  a wrist as a zero. `headline(unit:)` renders that as "5 reps", and a set
  prescribing nothing at all as "—".
- `GuidedSession` holds position only: which exercise, which set of it, and
  what to do when one is logged.
- `LiftingSessionRecorder` runs an `HKWorkoutSession` of
  `.traditionalStrengthTraining` with an `HKLiveWorkoutBuilder`, which
  surfaces current, average and maximum heart rate and saves the workout with
  its samples. Only one `HKWorkoutSession` may be live at a time, which the UI
  guarantees: an outdoor recording owns the whole screen.

### Food

- `RecentFoodsSnapshot` is a replace-in-place cache the phone pushes;
  `RecentFoodsSnapshotStore` keeps the last one.
- `WatchFoodLibrary` bundles the PWA's `foods.json` (7,793 USDA SR Legacy
  records, public domain), so a watch that has never met a phone can log food.
- `StandaloneFoodLog` retains every food logged here, up to 200, never by age,
  until the lifter exports it as QR codes (`StandaloneExport`, `QRCodeImage`:
  Core Image does not exist on watchOS) for the web app to scan. It is
  separate from `SyncOutbox` because `transferUserInfo` returns normally even
  with no iPhone ever paired, and the watch cannot read the OS queue back.
- **A food the phone has stored leaves that log.** A food logged from the
  phone's recent list goes to the phone as `FOOD_LOGGED` and into the log. The
  phone stores each food id once and answers with a `WORKOUT_SYNC_ACK` under the
  same id; `StandaloneFoodLog.acknowledge(syncID:)` then removes it, so an
  export never counts a meal LIFT for iPhone already has. Nothing is removed
  for having been *sent*: until the phone says it has the food, this watch may
  hold the only copy. A food from the bundled library never goes to the phone
  (there is no reference id it could resolve) and stays until exported.

## Device testing

The watch has no link of its own to the Mac: installs ride the paired iPhone's
connection, so when an install fails, **check the phone first** (plugged in,
unlocked, trusted). `devicectl`'s "available (paired)" does not mean
unreachable; `xcrun xctrace list devices` is the more reliable view, and Xcode's
Devices and Simulators window shows the real error when `devicectl` will not.
The watch has two ids: `devicectl` wants the CoreDevice UUID, `xcodebuild`'s
`-destination` the hardware UDID.

What only hardware can show:

1. **`transferUserInfo`, both ways.** Push a routine from Routines with the watch
   app closed, then open it: the plan should be there. Log a food on the watch
   with LIFT for iPhone not running, then open it: the food should be in today's
   log, and gone from the watch's Export Foods.
2. **The HealthKit prompt** for the new bundle id, and a heart rate during a
   lifting session.
3. Launching can be refused while the watch is on its charger or wrist-down
   ("Navigation away from clock is not allowed"); open LIFT from the app list.
