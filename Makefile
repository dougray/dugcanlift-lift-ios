SCHEME      := Lift
BUNDLE_ID   := com.dugcanlift.lift
SIM         := iPhone 17 Pro
DERIVED     := .build/DerivedData
APP         := $(DERIVED)/Build/Products/Debug-iphonesimulator/Lift.app
DEST        := platform=iOS Simulator,name=$(SIM)

# xcbeautify makes xcodebuild output readable. brew install xcbeautify
# Falls back to raw output if it isn't installed.
PRETTY := $(shell command -v xcbeautify 2>/dev/null || echo cat)

.PHONY: help project build test run clean sim logs reset-sim doctor

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

sim: ## Boot the simulator and open it
	@xcrun simctl boot "$(SIM)" 2>/dev/null || true
	@open -a Simulator

run: build sim ## Build, install and launch on the simulator
	@xcrun simctl install booted "$(APP)"
	@xcrun simctl launch booted $(BUNDLE_ID)

logs: ## Tail the app's log output
	@xcrun simctl spawn booted log stream \
		--predicate 'subsystem CONTAINS "$(BUNDLE_ID)"' \
		--level debug

reset-sim: ## Wipe simulator data — the reliable way to test a fresh install
	@xcrun simctl uninstall booted $(BUNDLE_ID) 2>/dev/null || true

clean: ## Remove build artifacts and the generated project
	@rm -rf $(DERIVED) Lift.xcodeproj
	@echo "Cleaned. Run 'make project' to regenerate."

doctor: ## Check that required tooling is present
	@command -v xcodegen  >/dev/null && echo "xcodegen    ok" || echo "xcodegen    MISSING  → brew install xcodegen"
	@command -v xcbeautify >/dev/null && echo "xcbeautify  ok" || echo "xcbeautify  missing  → brew install xcbeautify (optional)"
	@command -v claude    >/dev/null && echo "claude      ok" || echo "claude      MISSING  → curl -fsSL https://claude.ai/install.sh | bash"
	@xcodebuild -version | head -1
	@xcrun simctl list devices available | grep -q "$(SIM)" && echo "simulator   ok ($(SIM))" || echo "simulator   '$(SIM)' not found — set SIM in Makefile"
