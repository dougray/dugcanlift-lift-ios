SCHEME      := LiftWatch
BUNDLE_ID   := com.dugcanlift.watch
SIM         := Apple Watch Series 11 (46mm)
DERIVED     := .build/DerivedData
# The product is LIFT.app, not LiftWatch.app — the scheme and the bundle name
# differ, which is easy to trip over when hand-writing an install path.
APP         := $(DERIVED)/Build/Products/Debug-watchsimulator/LIFT.app
DEST        := platform=watchOS Simulator,name=$(SIM)

# --- Real hardware -----------------------------------------------------------
#
# Its own derived-data path: device and simulator slices differ, and sharing
# one path makes every switch a full rebuild.
WATCH_DERIVED := .build/DerivedData-device
WATCH_APP     := $(WATCH_DERIVED)/Build/Products/Debug-watchos/LIFT.app

# The paired Apple Watch, as devicectl identifies it. Override for a specific
# one:  make watch WATCH=4D719BE4-2671-5442-9549-24676B854EB2
#
# Note there are TWO ids for the same watch and they are not interchangeable:
# devicectl uses a CoreDevice UUID (4D719BE4-…), xcodebuild's -destination
# uses the hardware UDID (00008310-…). `make watch-destinations` prints the
# latter; this variable wants the former.
WATCH ?= $(shell xcrun devicectl list devices 2>/dev/null | awk '/Watch/ {print $$3; exit}')

PRETTY := $(shell command -v xcbeautify 2>/dev/null || echo cat)

.PHONY: help project build test sim run clean doctor devices watch-destinations watch-build watch

help:
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

project: ## Regenerate LiftWatch.xcodeproj from project.yml
	xcodegen generate

# Reads the last line and you will think nothing ran: swift-testing prints
# "Test run with 0 tests in 0 suites passed" because every test here is XCTest,
# and that summary counts only swift-testing suites. The real count is the
# "Executed N tests" line above it.
test: ## Run the LiftKit domain tests (no simulator needed)
	swift test --package-path LiftKit

build: project ## Build for the watch simulator
	@set -o pipefail && xcodebuild \
		-project LiftWatch.xcodeproj \
		-scheme $(SCHEME) \
		-destination '$(DEST)' \
		-derivedDataPath $(DERIVED) \
		build | $(PRETTY)

sim: ## Boot the watch simulator
	@xcrun simctl boot "$(SIM)" 2>/dev/null || true
	@open -a Simulator

run: build sim ## Build, install and launch on the watch simulator
	@xcrun simctl install booted "$(APP)"
	@xcrun simctl launch booted $(BUNDLE_ID)

devices: ## List paired watches as devicectl sees them
	@xcrun devicectl list devices

watch-destinations: ## List watch destinations as xcodebuild sees them
	@xcodebuild -project LiftWatch.xcodeproj -scheme $(SCHEME) -showdestinations 2>/dev/null \
		| grep -E 'platform:watchOS,' || true

watch-build: project ## Build for a real Apple Watch (no install)
	@test -n "$(WATCH)" || { echo "No paired Apple Watch found. 'make devices' lists what is visible."; exit 1; }
	@set -o pipefail && xcodebuild \
		-project LiftWatch.xcodeproj \
		-scheme $(SCHEME) \
		-destination 'generic/platform=watchOS' \
		-derivedDataPath $(WATCH_DERIVED) \
		-allowProvisioningUpdates \
		build | $(PRETTY)

watch: watch-build ## Build and install on a real Apple Watch
	@echo "Installing on $(WATCH)..."
	@xcrun devicectl device install app --device $(WATCH) "$(WATCH_APP)" || { \
		echo ""; \
		echo "Install failed. Try it again first -- then check the PAIRED IPHONE,"; \
		echo "not the watch:"; \
		echo ""; \
		echo "    xcrun devicectl list devices"; \
		echo ""; \
		echo "The watch has no independent link to this Mac -- deployment rides"; \
		echo "the phone's connection. When the phone drops, the watch goes with"; \
		echo "it, and every error still describes the watch. The whole diagnosis"; \
		echo "is one device to the left of where the message points."; \
		echo ""; \
		echo "  * Reconnect the iPhone: plug it in, unlock it, trust this Mac."; \
		echo "    A watch install rides that link, so a phone xctrace calls"; \
		echo "    offline takes the watch with it."; \
		echo ""; \
		echo "  * Do not trust the State column. 'available (paired)' does NOT"; \
		echo "    mean unreachable -- installs succeed in that state routinely."; \
		echo "    'xcrun xctrace list devices' is the reliable view."; \
		echo ""; \
		echo "  * Still stuck: Xcode > Window > Devices and Simulators shows the"; \
		echo "    real error, which devicectl never does. If the phone is absent"; \
		echo "    there too, CoreDevice is stale and a Mac restart clears it."; \
		echo ""; \
		echo "  * Developer Mode on the watch matters but is rarely the cause."; \
		echo ""; \
		echo "The build above already succeeded -- nothing needs rebuilding."; \
		exit 1; }

clean: ## Remove build artifacts and the generated project
	@rm -rf $(DERIVED) $(WATCH_DERIVED) LiftWatch.xcodeproj
	@echo "Cleaned. Run 'make project' to regenerate."

doctor: ## Check that required tooling and devices are present
	@command -v xcodegen   >/dev/null && echo "xcodegen    ok" || echo "xcodegen    MISSING  → brew install xcodegen"
	@command -v xcbeautify >/dev/null && echo "xcbeautify  ok" || echo "xcbeautify  missing  → brew install xcbeautify (optional)"
	@xcodebuild -version | head -1
	@xcrun simctl list devices available | grep -q "$(SIM)" && echo "simulator   ok ($(SIM))" || echo "simulator   '$(SIM)' not found — set SIM in Makefile"
	@test -n "$(WATCH)" && echo "watch       paired ($(WATCH))" || echo "watch       none paired — 'make watch' needs one"
