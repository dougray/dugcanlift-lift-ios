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

# --- Real hardware -----------------------------------------------------------
#
# A separate derived-data path, because a device build and a simulator build
# produce different slices and sharing one path makes every switch a full
# rebuild.
DEVICE_DERIVED := .build/DerivedData-device
DEVICE_APP     := $(DEVICE_DERIVED)/Build/Products/Debug-iphoneos/Lift.app

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
DEVICE ?= $(shell xcrun devicectl list devices 2>/dev/null | awk '/iPhone|iPad/ { for (i = 1; i <= NF; i++) if ($$i ~ /^[0-9A-Fa-f]{8}-[0-9A-Fa-f-]+$$/) { print $$i; exit } }')

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

.PHONY: help project build test run clean sim logs reset-sim doctor devices device device-build signing

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

test: project ## Run unit tests
	@set -o pipefail && xcodebuild \
		-project Lift.xcodeproj \
		-scheme $(SCHEME) \
		-destination '$(DEST)' \
		-derivedDataPath $(DERIVED) \
		test | $(PRETTY)

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
		-scheme $(SCHEME) \
		-destination 'generic/platform=iOS' \
		$(FREE_ENTITLEMENTS) \
		-showBuildSettings 2>/dev/null \
		| awk '/^Build settings for action build and target/ { t = $$NF; sub(/:$$/, "", t) } t != "" && /^ +CODE_SIGN_ENTITLEMENTS = / { printf "  %-14s %s\n", t, $$3 }'

device: device-build ## Build, install and launch on a connected device
	@echo "Installing on $(DEVICE)..."
	@xcrun devicectl device install app --device $(DEVICE) "$(DEVICE_APP)"
	@xcrun devicectl device process launch --device $(DEVICE) --terminate-existing $(BUNDLE_ID)
	@echo
	@echo "This is a DEBUG build. LiftStore.makeContainer deletes the store and"
	@echo "starts fresh if the container fails to open -- fine on a simulator,"
	@echo "your real training history on a phone. Save a backup from Settings"
	@echo "before installing a build that changes the schema."

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
	@test -n "$(DEVICE)" && echo "device      ok ($(DEVICE))" || echo "device      none connected — 'make device' needs one"
