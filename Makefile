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
		echo "Install failed. In order of likelihood:"; \
		echo ""; \
		echo "  1. Developer Mode is off ON THE WATCH. Settings > Privacy &"; \
		echo "     Security > Developer Mode, then restart it when asked. A"; \
		echo "     watch only ever paired to a phone will not have this on, and"; \
		echo "     nothing on the Mac can turn it on."; \
		echo "  2. The watch is locked, off the wrist, or not on this Mac's"; \
		echo "     Wi-Fi. Watch installs go over the network, not a cable."; \
		echo "  3. It failed preparation earlier and will not retry on its own."; \
		echo "     Xcode > Window > Devices and Simulators, select the watch,"; \
		echo "     let it finish. That step has no command-line equivalent, and"; \
		echo "     it is where the real error message appears."; \
		echo ""; \
		echo "Symptoms that mean this rather than a build problem: devicectl"; \
		echo "says 'The device rejected the connection request', or xcodebuild"; \
		echo "says 'may need to be unlocked to recover from previously reported"; \
		echo "preparation errors'. The build above already succeeded — nothing"; \
		echo "needs rebuilding once the watch is reachable."; \
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
