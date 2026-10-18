SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

PROJECT := VaultLight.xcodeproj
SCHEME  := VaultLight
CORE    := Packages/VaultLightCore
DERIVED := .build/DerivedData
SOURCES := App Packages/VaultLightCore/Sources Packages/VaultLightCore/Tests

SWIFT_FORMAT := $(shell command -v swift-format 2>/dev/null || echo "xcrun swift-format")
BEAUTIFY     := $(shell command -v xcbeautify >/dev/null 2>&1 && echo "| xcbeautify --quiet" || echo "")

.PHONY: help bootstrap gen test-core test-fake-bw perf build build-signed run lint format strings check-strings check clean

help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-14s %s\n",$$1,$$2}'

bootstrap: ## Install tools via Homebrew and create Configs/Local.xcconfig
	brew bundle --file=Brewfile
	@for f in Tests/Fixtures/bw-fake/bw Tests/Fixtures/bw-fake/smoke-test.sh scripts/*.sh; do \
		if [ -e "$$f" ]; then chmod +x "$$f"; fi; \
	done
	@if [ ! -f Configs/Local.xcconfig ]; then \
		cp Configs/Local.xcconfig.example Configs/Local.xcconfig; \
		echo "Created Configs/Local.xcconfig: set VL_TEAM_ID and VL_BUNDLE_ID."; \
	fi

gen: ## Generate VaultLight.xcodeproj from project.yml
	xcodegen generate --quiet

test-core: ## Run VaultLightCore unit tests
	swift test --package-path $(CORE)

test-fake-bw: ## Smoke-test the fake bw CLI used by tests
	Tests/Fixtures/bw-fake/smoke-test.sh

perf: ## Run performance tests in release mode
	swift test --package-path $(CORE) -c release --filter Performance

build: gen ## Build the app (Debug, unsigned)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED) \
		CODE_SIGNING_ALLOWED=NO build $(BEAUTIFY)

build-signed: gen ## Build the app (Debug, signed with your team from Configs/Local.xcconfig)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED) \
		-allowProvisioningUpdates build $(BEAUTIFY)

run: build-signed ## Build signed and launch the app
	open "$(DERIVED)/Build/Products/Debug/VaultLight.app"

# The compiler writes the localizable strings it finds (SWIFT_EMIT_LOC_STRINGS) next to each target's objects.
INTERMEDIATES := $(DERIVED)/Build/Intermediates.noindex
APP_STRINGS   := App/Localizable.xcstrings
CORE_STRINGS  := $(CORE)/Sources/VaultLightCore/Resources/Localizable.xcstrings

strings: build ## Add new strings to the String Catalogs (run after changing UI copy)
	@$(MAKE) --no-print-directory sync-strings APP_CATALOG=$(APP_STRINGS) CORE_CATALOG=$(CORE_STRINGS)

check-strings: ## Fail when a String Catalog is missing strings from the last build
	@# sync matches a catalog to its table by file name, so the copies keep the name Localizable.xcstrings.
	@tmp=$$(mktemp -d); mkdir "$$tmp/app" "$$tmp/core"; \
	cp $(APP_STRINGS) "$$tmp/app/"; cp $(CORE_STRINGS) "$$tmp/core/"; \
	$(MAKE) --no-print-directory sync-strings \
		APP_CATALOG="$$tmp/app/Localizable.xcstrings" CORE_CATALOG="$$tmp/core/Localizable.xcstrings" >/dev/null; \
	if ! cmp -s "$$tmp/app/Localizable.xcstrings" $(APP_STRINGS) \
		|| ! cmp -s "$$tmp/core/Localizable.xcstrings" $(CORE_STRINGS); then \
		echo "String Catalogs are out of date: run make strings and commit them." >&2; rm -rf "$$tmp"; exit 1; \
	fi; rm -rf "$$tmp"; echo "String Catalogs up to date"

.PHONY: sync-strings
sync-strings:
	xcrun xcstringstool sync $(APP_CATALOG) --stringsdata $$(find $(INTERMEDIATES)/VaultLight.build -name '*.stringsdata')
	xcrun xcstringstool sync $(CORE_CATALOG) --stringsdata $$(find $(INTERMEDIATES)/VaultLightCore.build -name '*.stringsdata')

lint: ## SwiftLint + swift-format lint
	swiftlint lint --strict --quiet
	$(SWIFT_FORMAT) lint --strict --recursive --configuration .swift-format $(SOURCES)

format: ## Format Swift sources in place
	$(SWIFT_FORMAT) format --in-place --recursive --configuration .swift-format $(SOURCES)

check: lint test-fake-bw test-core build check-strings ## Everything CI runs

clean: ## Remove build products and the generated project
	rm -rf .build $(CORE)/.build $(PROJECT)
