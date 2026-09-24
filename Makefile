SCHEME      := Lift
BUNDLE_ID   := com.dugcanlift.lift
# The simulator to build, test and run on. Detected rather than pinned: a
# hard-coded model is wrong the moment Xcode ships a new one or this checkout
# moves to another Mac, and the failure -- "Unable to find a device matching
# the provided destination specifier" -- names the destination, not the cause.
# A booted iPhone wins, because it is already on screen and needs no boot;
# otherwise the first available iPhone. Override for a specific model:
#   make test SIM="iPhone 18 Pro"
#
# LPAREN carries the "(" that separates a simulator's name from its UDID: make
# counts parentheses while it parses $(shell ...), so a bare one inside the
# awk program ends the call early ("unterminated call to function `shell'").
LPAREN      := (
SIM         := $(shell xcrun simctl list devices available 2>/dev/null | awk '/^ +iPhone/ { n = substr($$0, 1, index($$0, " $(LPAREN)") - 1); sub(/^ +/, "", n); if (!f) f = n; if ($$0 ~ /Booted/) { print n; d = 1; exit } } END { if (!d) print f }')
DERIVED     := .build/DerivedData
APP         := $(DERIVED)/Build/Products/Debug-iphonesimulator/Lift.app
DEST        := platform=iOS Simulator,name=$(SIM)

# --- The watch app -----------------------------------------------------------
#
# LIFT for Apple Watch is a target of this project (Watch/, scheme LiftWatch),
# embedded in Lift.app at Lift.app/Watch/LIFT.app. The product is LIFT.app,
# not LiftWatch.app.
#
# The watch simulator is the one paired with $(SIM), because the watch app
# only reaches the phone app through WatchConnectivity, and that only runs
# between a pair. Failing a pair, a booted watch, then the first available
# one. Override for a specific model:
#   make watch-run WATCH_SIM="Apple Watch Ultra 4 (49mm)"
#
# A watch's name has its own parentheses ("Apple Watch Series 12 (46mm)"), so
# a name is everything before the " (UDID)", not before the first "(".
WATCH_SIM   := $(shell sim='$(SIM)'; xcrun simctl list pairs 2>/dev/null | awk -v sim="$$sim" 'function nm(l) { sub(/^ +(Watch|Phone): /, "", l); return match(l, / \([0-9A-Fa-f-]{36}\)/) ? substr(l, 1, RSTART - 1) : "" } /^ +Watch: / { w = nm($$0) } /^ +Phone: / && nm($$0) == sim { print w; exit }')
ifeq ($(strip $(WATCH_SIM)),)
WATCH_SIM   := $(shell xcrun simctl list devices available 2>/dev/null | awk '/^ +Apple Watch/ { l = $$0; sub(/^ +/, "", l); if (!match(l, / \([0-9A-Fa-f-]{36}\)/)) next; n = substr(l, 1, RSTART - 1); if (!f) f = n; if (l ~ /Booted/) { print n; d = 1; exit } } END { if (!d) print f }')
endif
WATCH_SCHEME := LiftWatch
WATCH_BUNDLE_ID := com.dugcanlift.lift.watchkitapp
WATCH_DEST  := platform=watchOS Simulator,name=$(WATCH_SIM)
# Built inside the iPhone app by `make build`. The simulator does not install
# an embedded watch app on the paired watch the way a real iPhone's Watch app
# does, so watch-run installs it by hand, as Xcode itself does.
EMBEDDED_WATCH_APP := $(APP)/Watch/LIFT.app

# --- Real hardware -----------------------------------------------------------
#
# A separate derived-data path, because a device build and a simulator build
# produce different slices and sharing one path makes every switch a full
# rebuild.
DEVICE_DERIVED := .build/DerivedData-device
DEVICE_APP     := $(DEVICE_DERIVED)/Build/Products/Debug-iphoneos/Lift.app

# The watch app a device build embeds, for installing on a real watch.
DEVICE_WATCH_APP := $(DEVICE_APP)/Watch/LIFT.app

# The paired Apple Watch, as devicectl identifies it. Override for a specific
# one:  make watch-device WATCH=4D719BE4-2671-5442-9549-24676B854EB2
#
# There are TWO ids for the same watch and they are not interchangeable:
# devicectl uses a CoreDevice UUID (4D719BE4-...), xcodebuild's -destination
# the hardware UDID (00008310-...). This wants the first.
#
# devicectl lists simulators too, with "simulated" in its Reality column, and
# a watch simulator is no place for a device build, so those rows are skipped.
WATCH ?= $(shell xcrun devicectl list devices 2>/dev/null | awk '/Watch/ && !/simulated/ { for (i = 1; i <= NF; i++) if ($$i ~ /^[0-9A-Fa-f]{8}-[0-9A-Fa-f-]+$$/) { print $$i; exit } }')

# The first iPhone or iPad devicectl knows about. Override for a specific one:
#   make device DEVICE=901D197D-95D6-5FA6-B188-6C827D7B0109
#
# Matched by shape, not by column: devicectl's table gained a "(UDID)" label
# after this was written and $3 became that literal string, so every install
# had to pass DEVICE= by hand.
#
# Deliberately NOT filtered on State. This used to require "connected", on the
# assumption that "available (paired)" meant unreachable. It does not: installs
# succeed against a device in that state routinely, and the stricter filter
# refused to even try -- so every install had to pass DEVICE= by hand, which
# defeats the target. A device that really is unreachable fails at the install
# with a clear CoreDevice error, which is better than a build that declines to
# start.
#
# Rows marked "simulated" are skipped: devicectl lists simulators alongside
# real devices now (its Reality column says which), sorted by name. Today's
# phone, "Mjolnir", sorts ahead of every "iPad ..."/"iPhone ..." simulator
# only because of its capital M; a device named "stormbringer" sorts after
# them, and with no phone attached at all the first simulator was taken as
# the device instead of the "No iPhone or iPad visible" message below.
DEVICE ?= $(shell xcrun devicectl list devices 2>/dev/null | awk '/iPhone|iPad/ && !/simulated/ { for (i = 1; i <= NF; i++) if ($$i ~ /^[0-9A-Fa-f]{8}-[0-9A-Fa-f-]+$$/) { print $$i; exit } }')

# Signing on a free Apple Personal Team cannot include Associated Domains, and
# the app declares it for Universal Links. Building for a device with the
# normal entitlements fails outright:
#
#   Personal development teams ... do not support the Associated Domains
#   capability.
#
# Config/Lift-free.entitlements is the same file without it. Passing it as a
# build setting keeps project.yml and the committed entitlements untouched, so
# a paid team still gets the real capability with no edit to undo.
#
# Through a per-target setting, not CODE_SIGN_ENTITLEMENTS=<file> directly: a
# command-line build setting applies to every target in the build, so that
# signed the widgets, and would sign the watch app, with this app's HealthKit
# and App Group entitlements instead of their own. FREE_TEAM_ENTITLEMENTS is
# set on the Lift target only (project.yml); every other target finds it
# empty and keeps what $(inherited) gives it, its own entitlements file.
# `make signing` prints what each target ends up with.
#
# The cost is that Universal Links do not work in a device build made this way
# -- tapping a dugcanlift.com plan link opens the browser. That capability has
# never worked on a free team anyway, which is why Coach iOS ingests links by
# paste.
FREE_ENTITLEMENTS := CODE_SIGN_ENTITLEMENTS='$$(FREE_TEAM_ENTITLEMENTS:default=$$(inherited))'

# xcbeautify makes xcodebuild output readable. brew install xcbeautify
# Falls back to raw output if it isn't installed.
PRETTY := $(shell command -v xcbeautify 2>/dev/null || echo cat)

.PHONY: help project build test app-test watch-test run clean sim logs reset-sim doctor devices device device-build signing watch watch-sim watch-run watch-device

help:
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

project: ## Regenerate Lift.xcodeproj from project.yml
	xcodegen generate

build: project ## Build for the simulator
	@set -o pipefail && xcodebuild \
		-project Lift.xcodeproj \
		-scheme $(SCHEME) \
		-destination '$(DEST)' \
		-derivedDataPath $(DERIVED) \
		build | $(PRETTY)

test: app-test watch-test ## Run every unit test: the app's and the watch package's

app-test: project ## Run the app's unit tests on the iPhone simulator
	@set -o pipefail && xcodebuild \
		-project Lift.xcodeproj \
		-scheme $(SCHEME) \
		-destination '$(DEST)' \
		-derivedDataPath $(DERIVED) \
		test | $(PRETTY)

# The watch app's domain logic, plain Swift with no simulator. Read the
# "Executed N tests" line: the last line is swift-testing's own summary, which
# says "0 tests in 0 suites" because every test here is XCTest.
watch-test: ## Run the watch package's tests (swift test, no simulator)
	swift test --package-path Watch/LiftWatchKit

sim: ## Boot the simulator and open its window
	@xcrun simctl boot "$(SIM)" 2>/dev/null || true
# Xcode 27 removed Simulator.app and replaced it with DeviceHub.app
# (com.apple.dt.Devices), which also moved to Contents/Applications. Try both
# and never fail the target over it: `simctl install` and `launch` work against
# a booted device whether or not any window is showing it, so a missing window
# app must not stop `make run`.
	@open -a Simulator 2>/dev/null \
		|| open -b com.apple.dt.Devices 2>/dev/null \
		|| echo "Booted $(SIM). No simulator window app found; the app still installs and launches."

run: build sim ## Build, install and launch on the simulator
	@xcrun simctl install "$(SIM)" "$(APP)"
	@xcrun simctl launch "$(SIM)" $(BUNDLE_ID)

watch: project ## Build the watch app alone for the watch simulator
	@set -o pipefail && xcodebuild \
		-project Lift.xcodeproj \
		-scheme $(WATCH_SCHEME) \
		-destination '$(WATCH_DEST)' \
		-derivedDataPath $(DERIVED) \
		build | $(PRETTY)

watch-sim: ## Boot the watch simulator paired with $(SIM)
	@test -n "$(WATCH_SIM)" || { echo "No Apple Watch simulator found. Create one paired with $(SIM) in Xcode's Devices window."; exit 1; }
	@xcrun simctl boot "$(WATCH_SIM)" 2>/dev/null || true

# `run` builds Lift, which builds and embeds the watch app, and installs it on
# the phone. The paired watch simulator then needs the embedded app installed
# by hand. Both apps end up running, so WCSession on each side sees the other.
watch-run: run watch-sim ## Build, install and launch on the phone and its paired watch
	@test -d "$(EMBEDDED_WATCH_APP)" || { echo "$(EMBEDDED_WATCH_APP) is missing: Lift was built without its watch app."; exit 1; }
	@xcrun simctl install "$(WATCH_SIM)" "$(EMBEDDED_WATCH_APP)"
	@xcrun simctl launch "$(WATCH_SIM)" $(WATCH_BUNDLE_ID)

devices: ## List connected iPhones and iPads
	@xcrun devicectl list devices

device-build: project ## Build for a connected device (no install)
	@test -n "$(DEVICE)" || { echo "No iPhone or iPad visible at all. Plug one in, unlock it, and trust this Mac. 'make devices' lists what devicectl can see."; exit 1; }
	@set -o pipefail && xcodebuild \
		-project Lift.xcodeproj \
		-scheme $(SCHEME) \
		-destination 'platform=iOS,id=$(DEVICE)' \
		-derivedDataPath $(DEVICE_DERIVED) \
		$(FREE_ENTITLEMENTS) \
		-allowProvisioningUpdates \
		build | $(PRETTY)

signing: project ## Show which entitlements each target signs with in a device build
	@xcodebuild \
		-project Lift.xcodeproj \
		-alltargets \
		$(FREE_ENTITLEMENTS) \
		-showBuildSettings 2>/dev/null \
		| awk '/^Build settings for action build and target/ { t = $$NF; sub(/:$$/, "", t) } t != "" && /^ +CODE_SIGN_ENTITLEMENTS = / && !seen[t]++ { printf "  %-14s %s\n", t, $$3 }'

device: device-build ## Build, install and launch on a connected device
	@echo "Installing on $(DEVICE)..."
	@xcrun devicectl device install app --device $(DEVICE) "$(DEVICE_APP)"
	@xcrun devicectl device process launch --device $(DEVICE) --terminate-existing $(BUNDLE_ID)
	@echo
	@echo "This is a DEBUG build. LiftStore.makeContainer deletes the store and"
	@echo "starts fresh if the container fails to open -- fine on a simulator,"
	@echo "your real training history on a phone. Save a backup from Settings"
	@echo "before installing a build that changes the schema."

# The watch app comes from `make device-build`: Lift's device build embeds it,
# signed with its own entitlements. The watch has no link of its own to this
# Mac; the install rides the paired iPhone's connection.
watch-device: device-build ## Install the embedded watch app on the paired Apple Watch
	@test -n "$(WATCH)" || { echo "No paired Apple Watch visible. 'make devices' lists what devicectl can see."; exit 1; }
	@echo "Installing $(DEVICE_WATCH_APP) on $(WATCH)..."
	@xcrun devicectl device install app --device $(WATCH) "$(DEVICE_WATCH_APP)" || { \
		echo ""; \
		echo "Install failed. Try it again first -- then check the PAIRED IPHONE,"; \
		echo "not the watch. The watch has no independent link to this Mac:"; \
		echo "deployment rides the phone's connection, and when the phone drops"; \
		echo "every error still describes the watch."; \
		echo ""; \
		echo "  * Reconnect the iPhone: plug it in, unlock it, trust this Mac."; \
		echo "  * 'available (paired)' in devicectl's State column does NOT mean"; \
		echo "    unreachable. 'xcrun xctrace list devices' is the reliable view."; \
		echo "  * Still stuck: Xcode > Window > Devices and Simulators shows the"; \
		echo "    real error, which devicectl never does."; \
		echo "  * Then the watch: unlocked, on the wrist, on this Mac's Wi-Fi,"; \
		echo "    Developer Mode on."; \
		echo ""; \
		echo "The build above already succeeded -- nothing needs rebuilding."; \
		exit 1; }
	@echo
	@echo "Installed. Launching is refused while the watch is on its charger or"
	@echo "wrist-down ('Navigation away from clock is not allowed'); open LIFT"
	@echo "from the watch's app list instead."

logs: ## Tail the app's log output
	@xcrun simctl spawn "$(SIM)" log stream \
		--predicate 'subsystem CONTAINS "$(BUNDLE_ID)"' \
		--level debug

reset-sim: ## Wipe simulator data — the reliable way to test a fresh install
	@xcrun simctl uninstall "$(SIM)" $(BUNDLE_ID) 2>/dev/null || true

clean: ## Remove build artifacts and the generated project
	@rm -rf $(DERIVED) $(DEVICE_DERIVED) Lift.xcodeproj
	@echo "Cleaned. Run 'make project' to regenerate."

doctor: ## Check that required tooling is present
	@command -v xcodegen  >/dev/null && echo "xcodegen    ok" || echo "xcodegen    MISSING  → brew install xcodegen"
	@command -v xcbeautify >/dev/null && echo "xcbeautify  ok" || echo "xcbeautify  missing  → brew install xcbeautify (optional)"
	@command -v claude    >/dev/null && echo "claude      ok" || echo "claude      MISSING  → curl -fsSL https://claude.ai/install.sh | bash"
	@xcodebuild -version | head -1
	@xcrun simctl list devices available | grep -q "$(SIM)" && echo "simulator   ok ($(SIM))" || echo "simulator   '$(SIM)' not found — set SIM in Makefile"
	@test -n "$(WATCH_SIM)" && echo "watch sim   ok ($(WATCH_SIM))" || echo "watch sim   none — pair an Apple Watch simulator with $(SIM)"
	@test -n "$(DEVICE)" && echo "device      ok ($(DEVICE))" || echo "device      none connected — 'make device' needs one"
	@test -n "$(WATCH)" && echo "watch       ok ($(WATCH))" || echo "watch       none paired — 'make watch-device' needs one"
