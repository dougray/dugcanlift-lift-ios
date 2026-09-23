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
- **`Sources/ShareExtension/`** — the `LiftShare` share extension (see "A
  coach's plan link, and why Universal Links are not the answer" below).

The SwiftData store lives in the App Group container
(`group.com.dugcanlift.lift`) so the widget extension can read it. Do not move it
to the app's private container.

## A coach's plan link, and why Universal Links are not the answer

A coach sends a plan as a link. `Config/Lift.entitlements` declares
`com.apple.developer.associated-domains: applinks:www.dugcanlift.com` and it
stays there for the day this is signed by a paid team -- but **a free Apple
Personal Team cannot sign Associated Domains at all**, which is why
`make device-build` swaps in `Config/Lift-free.entitlements`, and
dugcanlift.com serves no apple-app-site-association file. On Doug's own phone
a plan link therefore opens the browser, and nothing reaches the app.

Coach iOS hit this wall first and answered it with three doors that need no
entitlement. LIFT now has the same three, and they all ask **`PlanLinkIntake`**,
so a link that opens one way opens every way and one that fails, fails alike:

1. **`dugcanliftlift://plan#1z...`**, a custom URL scheme (`CFBundleURLTypes` in
   project.yml, `LiftApp.onOpenURL`). Exactly that spelling: not
   `dugcanliftcoach`, which is Coach iOS's, because a scheme claimed by two
   apps on one phone goes to whichever iOS picks.
2. **Paste a Plan Link** (`PastePlanLinkView`), in Settings under Coach -- the
   section that already holds the coach's email and Send to Coach. It is a
   push, not a sheet: Settings is itself a sheet, and a second `.sheet` on
   `CoachSection` opened the screen and closed both again.
3. **The share extension** (`LiftShare`, `Sources/ShareExtension/`). "LIFT"
   appears in the share sheet for a URL or text; it says what the plan is
   ("Plan from Doug · 1 workout · 1 scheduled day") or why it will not take it,
   and on Add queues the *fragment* in the existing App Group
   `group.com.dugcanlift.lift` (`PendingPlanLinks`). `LiftApp` drains the queue
   whenever the scene becomes active.

`LiftApp.onOpenURL` still handles the Universal Link unchanged, so the day
there is a paid team nothing has to be rewritten.

**Accepting a plan is still only `PlanPreviewView`.** No door imports
anything; each one ends at the same preview and the same `PlanImporter`.
The extension in particular **does not open the app and does not write
SwiftData** -- iOS gives a share extension no supported way to open its
containing app, and a routine appearing in someone's library from a share
sheet is not a decision the share sheet gets to make. It compiles only
`PlanLinkExtractor.swift`, `PlanLinkIntake.swift` and `PendingPlanLinks.swift`
from `Sources/Shared`, listed file by file, and links `LiftCore` only: never
SwiftData models, never `LiftReference`. It has its own
`PrivacyInfo.xcprivacy`, because an extension is its own bundle. It is a new
bundle id, `com.dugcanlift.lift.share`, so the next free-team device build
registers one more App ID (ten per seven days is the cap).

**`PlanLinkExtractor` is the one rule for finding a plan link in text**, and it
is a deliberate port of Coach iOS's `ShareLinkExtractor` -- **change one, change
both.** The first `www.dugcanlift.com/lift/#1z...`/`#1u...` (or
`dugcanliftlift:` URL) anywhere in the text wins, whatever surrounds it;
otherwise the whole text may be a bare fragment. Another site's URL carrying a
`#1z...` fragment is refused, and so is the lifter's own `/coach/#1z...` log
link, which travels the other way and gets its own sentence rather than "not a
link". It is not in LiftKit because moving it there is a kit tag plus a pinned
bump in two shipped apps, and Coach's copy is compiled into a shipped share
extension; a third app needing the rule is when to pay that cost.

**The lifter's id is mirrored into the App Group.** An extension has its own
`UserDefaults.standard` and cannot read `coachLifterID`, which
`PlanLinkCodec.decode` needs before it will return a payload at all.
`LiftApp.init` writes it to the group suite once. Before LIFT has ever been
opened there is nothing to mirror, and the extension says so rather than
queueing a plan it could not check.

**Safari shares the address without the plan**: `lift/app.js` strips the
fragment with `history.replaceState` as soon as it has read it, exactly as the
Coach web app does, so sharing from Safari after the page loaded sends
`https://www.dugcanlift.com/lift/`. `isLiftPageWithoutPlan` recognises that and
says to share from the message it arrived in instead.

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

**Large screens are laid out by width, never by device.** LIFT runs on iPad
(`TARGETED_DEVICE_FAMILY` 1,2, all four iPad orientations so multitasking
works). `RootView` measures the window: from 1024pt the tabs become a sidebar,
and every tab reads `\.pageWidth` to choose its columns through
`AdaptiveLayout` (two card columns from 640pt of content, Train's two halves
from 800pt, Cook's plan as seven day columns from 1000pt, forms and lists
capped at 700pt, everything at 1600pt). An iPad window at phone width is the
phone. Below every threshold the helpers are the plain leading `VStack` the
phone always had, so portrait iPhone must not change: compare screenshots
against main before merging a layout change. `AdaptiveColumns`/`AdaptiveGrid`
switch layouts through `AnyLayout`, not `if`, so crossing a breakpoint keeps
view state. The top bar and sidebar use `clearOfWindowControls`, or iPadOS 26's
window buttons sit on top of the Home tab.

**Saturated fat, sugar and sodium are tracked, never targeted.** No goal, no
bar, nothing "over". nil means the source did not say — never zero — so a
day's total covers only the foods that recorded each value and says so when
that is not all of them ("from 3 of 5 foods"). Display rounding, `fx`/`fe` in
Send to Coach and `ux` from a plan all go through LiftKit's `ShareNutrients`,
so the phone and the coach read the same number. The rules are
`NutrientDetailsDisplay`, `FoodEntryEdit` and `RecipeMacroEntry`, not views.

**A set may record a side, and absent is "both" forever.** `SetEntry.sideRaw`
is schema V8 (`LiftPreSideShapes` freezes what V6 and V7 shipped, and
`Tests/Fixtures/v7-simulator.store` is a store the V7 binary wrote). Nothing is
backfilled: every set logged before this is two-sided, which is honest, and no
decoder anywhere should guess a side from an exercise name. Whether a lift is
logged per limb is the lifter's choice, kept in `perSideExercises` keyed
`name|equipment` — `UnilateralGuess` only pre-ticks the box, and a "no" on a
name it says yes to must stick. **Its terms are matched as whole words**, over
a name with everything that is not a letter or a digit turned into a space:
one list, shared term for term with LIFT web's `UNILATERAL_TERMS`
(`lift/sides.js`), LIFT for Android's `PerSideLogging` and Coach iPhone's
`UnilateralGuess`, so change a term in all four or in none. It was a substring
match until 2026-09, which pre-ticked a cold plunge for "lunge" — every
singular and plural is listed rather than matched by prefix, and the "-ed"
spellings too ("One-Legged Deadlift"), precisely because whole words cannot
see a shorter term inside a longer word. No bundled exercise name reads
differently either way; the names this gets wrong are the ones a coach types
into a plan.

**A lift's identity is name, equipment *and* side** wherever sets are grouped
or charted (`LiftKey`), for the same reason equipment joined it: a left-arm row
and a right-arm row are not the same lift. A two-sided lift is untouched — one
series, no imbalance figure. The maths is `LiftProgression`, a value type with
no view in it and unit tests, because a rule in a view's `@State` cannot be
tested and this one decides what someone is told about their own body.
**Tracked and shown, never targeted**, exactly as saturated fat, sugar and
sodium are: no threshold, no colour, no prompt to fix anything.

**On the wire, side is bits 1-2 of the share tuple's `flags`** (0 both, 1 left,
2 right) and a named `side` field in a backup, omitted when both. Bits in the
link so the tuple stays six fields and an older decoder still reads the weight
and the reps; a name in the backup because that file is read by people and by
three platforms. The documents in the `dugcanlift-coach` repo are the contract;
`PerLimbTests` pins this side of it.

**A coach's plan can carry sides** (PLAN-FORMAT.md "Sides"): `b: 1` on an
exercise done each side, and a sixth set-tuple position naming a side, read
masked through LiftKit's `PlanSetFlags`. Accepting an each-side exercise turns
per-side logging on for that lift. Starting it keeps the prescription with the
logged exercise: the header counts against it (`L 0/3 · R 0/3`, `L 4/3` when
over, never capped), Add set lands on the side the next unfilled prescribed set
names and takes its numbers, and sided sets are logged as they are done rather
than pre-filled; two-sided sets are copied in as before. A named set on a lift
not logged per side shows L / R until it is logged, without touching
`perSideExercises`. Progression, imbalance and volume read the log, never the
plan. The rules are `Prescription` (a port of LIFT web's `sides.js`).
**Where it is kept: `PlanSides`, a `UserDefaults` side-car**, keyed by the
routine's exercise and set ids and by the logged `ExerciseEntry` id -- not
properties on LiftKit's shared routine `@Model`s, which would mean freezing
`Routine`, `RoutineExercise` and `RoutinePrescribedSet` in every schema version
since V3, and not a V9 on `ExerciseEntry` for a suggestion. It is not in the
backup file: a restored session loses only its targets, never a set.
`PlanSidesDegradationTests` pins how a build without any of this reads such a
plan (as two-sided sets, weights intact) against Coach web's fixture
`Tests/Fixtures/web-plan-per-side.txt`; never regenerate it from Swift. The
watch's `WorkoutPlan` does not carry sides yet: that waits for the watch
companion move.

**A struct a model stores is part of the schema.** SwiftData flattens
`NutritionFacts` into one column per field on FoodEntry, Recipe and
PlannedMeal, so a new field in LiftKit is a schema change here. LiftKit 1.9.0's
`saturatedFatG` needed `LiftSchemaV7` and a frozen seven-field copy; without it
every existing install failed to open its store (134504). Verify any schema
change by installing over a store the previous build wrote, not only in tests —
`Tests/Fixtures/v6-simulator.store` is one.

**The watch is told what to lift, in kilograms, with blanks left blank.**
`PLAN_PUSHED` carries today's plan to LIFT watchOS: the routine a coach's
plan booked for today, or one the lifter sent by hand from Routines
(`WatchPlanPin`, a day-scoped `UserDefaults` pin rather than a field on the
shared `Routine` model). `WatchPlanBuilder` decides which, and `Sources/
Shared/WatchPlan.swift` holds the wire types — hand-mirrored from
`dugcanlift-lift-watch/shared/contracts/workout-sync.schema.json` exactly as
`SyncEnvelope` is, and pinned by `WatchPlanWireTests`. Three rules carry the
risk: the wire field is `weightKg` and `RoutinePrescribedSet.targetWeightKg`
is already kilograms, so nothing on that path converts; every prescribed
field is optional and a blank travels as an absent key, never a zero or a
`null`; and a re-push of an unchanged plan keeps its revision
(`WatchPlanRevisions` hashes the payload), because the watch ignores a
revision it has already seen. Delivery is `transferUserInfo` with
`sendMessage` as a fast path — but see that file's note: measured on a paired
simulator pair, this phone is not that watch's `WCSession` peer yet, and
nothing it sends arrives.

**Road Food ranks against Home's number and logs an ordinary entry.** The
rules are `RoadFoodRanking`, a port of LIFT web's `lift/road-food.js` with its
tests ported alongside -- change one, change both. What is left of today is
`RemainingMacros`, which Home's headline also reads. The curated list is
`Resources/road-food.json`, copied unchanged from `dugcanlift-kit/data/`; with no
file, a DEBUG build falls back to `RoadFoodSample` (web's fake-named fixture,
inside `#if DEBUG`) and a release build hides Road Food entirely. Blank stays
blank: a missing fibre, saturated fat, sugar or sodium logs as nil, and an item
missing one of the four core macros is not logged at all, because
`NutritionFacts` would store it as zero. No location, ever.

**Two dates, and the warning keys off the chain's.** `checkedOn` is the day a
person read a chain's chart; `publishedOn` is the date the chart **states about
itself**, optional and only as precise as the document is -- `"2021-03-29"`
where Whataburger's says "as of March 29, 2021", `"2022-11"` where Burger
King's says only "NOVEMBER 2022", and absent where the document states none.
`RoadFoodRanking.ageDate` picks the first over the second and `isStale`
measures six calendar months from it, so a 2021 chart read this morning says
so: "These numbers are from the chain's chart dated Mar 29, 2021." A chain with
no document date keeps the older sentence word for word. Both dates are on
screen ("Published Nov 2022 · checked Sep 23, 2026"), because what a chain
published and when someone read it are different facts. `publishedText` never
prints a date more precisely than the document wrote it: "Nov 2022", never
"Nov 1, 2022".

**A coach's road picks arrive in the plan link and only reorder.** `rf`
(PLAN-FORMAT.md "Road picks") is a flat list of Road Food item ids. It is read
**app-side**, by `RoadPickLink`, off the same fragment `PlanLinkCodec` just
accepted -- not by a field on LiftKit's `PlanPayload`, because the kit is
pinned to an exact tag Coach iOS shares and a list of strings is not worth a
tag plus a bump in two shipped apps. `PlanLinkIntake.IncomingPlan` carries the
payload and the picks together from every door, so no screen can accept a plan
and drop its picks, and `rf` is **in `PlanImporter.hash`** or a coach resending
the same week with a different answer would have the link refused as already
imported. An empty list writes no key into the hashed mirror, so every plan
without picks hashes exactly as it did before (`PlanRoadPicksTests`).

They are stored in `RoadPicks`, a `UserDefaults` side-car like `PlanSides`, and
are **not in the backup** -- the coach still holds them. A plan carrying picks
replaces them whole; a plan with no `rf` changes nothing, because that is also
what every older Coach and every recipe-only send looks like, so **clearing is
this phone's own action** on the Road Food screen. What they do is
`RoadFoodRanking.withPicks`: a **stable partition**, picks first inside each
group. The same items fit, in the same order among themselves; a pick that is a
little over stays in that group and one more than 10% over stays hidden. An id
this build's `road-food.json` does not have is **skipped silently and not
counted**, and is kept in storage rather than filtered on arrival. Rows say
"Doug's pick" in weight, never colour: shown, never targeted, like the nutrient
lines. `RoadPicksDegradationTests` pins what a build without any of this makes
of the same link, against Coach web's own fixture
`Tests/Fixtures/web-plan-road-picks.txt`; never regenerate it from Swift.

**The shell is a paged `TabView`, so `.onDelete` never opens.** `RootView`
wraps the five tabs in `.tabViewStyle(.page(...))`, which takes every
horizontal drag for itself -- a swipe on Home turns to Food, and on Routines,
the last page, it does nothing at all. Swipe-to-delete inside any tab is
therefore unreachable, however correct the code reads. A row that can be
deleted needs a button (`RoutinesView`) rather than `.onDelete`, and a new
`.onDelete` anywhere in this app is dead code. `OutdoorActivityListView` still
has one.

**Deleting a routine is `RoutineRemoval`**, not view code -- the rule
`PlanSides` follows and Coach's `ClientRemoval` follows, because a rule in a
view's `@State` cannot be tested and this one decides what somebody loses.
**What goes:** the `Routine`, by cascade its `RoutineExercise`s and their
`RoutinePrescribedSet`s, plus the three things that name a routine as a plain
value and no cascade reaches -- every `ScheduledSession` a coach booked it on
(left behind, one draws "Coach scheduled: X" forever and does nothing when
tapped), the `WatchPlanPin` when it is this routine, and this routine's
`PlanSides.eachSide` / `.sides` entries. **What stays:** every workout already
logged from it, which is the whole point of snapshotting a name and its numbers
at log time, and `PlanSides.logged`, which is deliberately a copy rather than a
link back. It is one `save()`, so a failure rolls back whole. The confirmation
always says what stays and leaves a count of zero out entirely, the distinction
Coach's own confirmation makes.

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
