.PHONY: build run test test-all test-model-pack clean xcode generate models \
	model-venv model-venv-hf verify-models verify-app-models release archive \
	sign notarize appcast version

# XcodeGen must be installed: brew install xcodegen
XCODEGEN := $(shell command -v xcodegen 2>/dev/null)
PROJECT  := FreeFlow.xcodeproj
SCHEME   := FreeFlowApp
CONFIG   := Debug
XCODE_FLAGS := -skipPackagePluginValidation
MODEL_MANIFEST := FreeFlowApp/models.json
MODEL_VENV     := FreeFlowApp/.model-work/venv
MODEL_PYTHON   := $(MODEL_VENV)/bin/python3
HF_VERSION     := 1.11.0
MODEL_REQUIREMENTS := scripts/model-requirements.txt

# Release settings
TEAM_ID          := U5Y82TZF5K
SIGN_IDENTITY    := Developer ID Application: Mrinal Wadhwa ($(TEAM_ID))
NOTARIZE_PROFILE := freeflow-notarize
ARCHIVE_PATH     := build/FreeFlow.xcarchive
APP_PATH         := build/FreeFlow.app
RELEASE_DIR      := releases
DMG_NAME         := FreeFlow.dmg
DMG_PATH         := $(RELEASE_DIR)/$(DMG_NAME)
DMG_STAGING      := build/dmg_contents
DOWNLOAD_URL     := https://github.com/mrinalwadhwa/freeflow/releases/latest/download/
SPARKLE_BIN      := $(shell find ~/Library/Developer/Xcode/DerivedData/FreeFlow-*/SourcePackages/artifacts/sparkle/Sparkle/bin -maxdepth 0 2>/dev/null | head -1)

# Optional: set KEYCHAIN to a keychain path for CI builds.
# When set, codesign uses the specified keychain. Leave unset for local
# builds, which use the default keychain search list.
KEYCHAIN         ?=
ifdef KEYCHAIN
  KEYCHAIN_FLAGS := --keychain $(KEYCHAIN)
else
  KEYCHAIN_FLAGS :=
endif

# Generate the Xcode project from project.yml
generate:
ifndef XCODEGEN
	$(error "xcodegen not found. Install with: brew install xcodegen")
endif
	xcodegen generate

# Create or repair the isolated, repository-local model-tools environment.
# These are phony so a stale marker cannot hide a missing Python or package.
model-venv: scripts/bootstrap-model-venv.py
	@echo "Ensuring model-tools venv at $(MODEL_VENV)"
	@python3 scripts/bootstrap-model-venv.py --venv $(MODEL_VENV)

# Install the pinned network client only for explicit model materialization.
model-venv-hf: model-venv $(MODEL_REQUIREMENTS)
	@python3 scripts/bootstrap-model-venv.py \
		--venv $(MODEL_VENV) \
		--requirements $(MODEL_REQUIREMENTS) \
		--huggingface-version $(HF_VERSION)

# Download models listed in FreeFlowApp/models.json.
models: model-venv-hf
	@PATH="$(abspath $(MODEL_VENV)/bin):$$PATH" \
		$(MODEL_PYTHON) scripts/download-models.py

# Verify the complete model pack without network access.
verify-models: model-venv
	@$(MODEL_PYTHON) scripts/download-models.py --verify

# Verify the model pack copied into an extracted app archive.
verify-app-models: model-venv
	@cmp $(MODEL_MANIFEST) "$(APP_PATH)/Contents/Resources/models.json"
	@$(MODEL_PYTHON) scripts/verify-model-pack.py \
		--manifest "$(APP_PATH)/Contents/Resources/models.json" \
		--models-dir "$(APP_PATH)/Contents/Resources/models"

# Generate training data from YAML, then train a LoRA adapter
train:
	@cd training && python3 generate_training_data.py --no-casual --split
	@cd training && python3 -u -m mlx_lm.lora --config lora-config.yaml

# Build the app (generates project first if missing)
build: model-venv $(PROJECT)
	$(MODEL_PYTHON) scripts/download-models.py --run \
		xcodebuild $(XCODE_FLAGS) -project $(PROJECT) -scheme $(SCHEME) \
		-configuration $(CONFIG) build

# Build and launch
run: build
	@open "$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -showBuildSettings 2>/dev/null | grep -m1 ' BUILT_PRODUCTS_DIR' | awk '{print $$3}')/FreeFlow.app"

# Run all FreeFlowKit tests via Swift Package Manager (no Xcode project needed).
# swift test runs both XCTest-based and Swift Testing suites in one invocation,
# but the final summary line only counts Swift Testing tests. This target parses
# the full output to report a combined total from both frameworks.
#
# Output is written to /tmp/freeflow-test.log to avoid flooding the terminal.
# Only the summary line is printed. Inspect the log for details on failures.
TEST_LOG := /tmp/freeflow-test.log

test-model-pack: model-venv
	@$(MODEL_PYTHON) -m unittest discover -s scripts/tests -p 'test_*.py'

test: test-model-pack
	@echo "Running fast tests… output → $(TEST_LOG)"
	@cd FreeFlowKit && swift test > $(TEST_LOG) 2>&1; \
	exit_code=$$?; \
	xc_pass=`grep -c '^Test Case.*passed' $(TEST_LOG) || true`; \
	xc_fail=`grep -c '^Test Case.*failed' $(TEST_LOG) || true`; \
	st_fail=`grep -c '^✘ Test .* failed' $(TEST_LOG) || true`; \
	st_line=`grep 'Test run with' $(TEST_LOG) || true`; \
	st_total=`echo "$$st_line" | sed -n 's/.*with \([0-9]*\) tests.*/\1/p'`; \
	st_total=$${st_total:-0}; \
	xc_pass=$${xc_pass:-0}; \
	xc_fail=$${xc_fail:-0}; \
	st_fail=$${st_fail:-0}; \
	total=`expr $$xc_pass + $$xc_fail + $$st_total`; \
	fail=`expr $$xc_fail + $$st_fail`; \
	echo ""; \
	if [ $$exit_code -ne 0 ] || [ $$fail -ne 0 ]; then \
		echo "── FAILURES ──"; \
		grep -E '✘ Test |✘ Suite |^Test Case.*failed' $(TEST_LOG) | head -20; \
		echo ""; \
	fi; \
	echo "── Combined: $$total tests (`expr $$xc_pass + $$xc_fail` XCTest + $$st_total Swift Testing), $$fail failures ──"; \
	echo "Full log: $(TEST_LOG)"; \
	exit $$exit_code

# Run all tests including Keychain-dependent suites (requires macOS login Keychain access).
test-all: test-model-pack
	@echo "Running all tests (including Keychain + slow)… output → $(TEST_LOG)"
	@cd FreeFlowKit && FREEFLOW_TEST_KEYCHAIN=1 FREEFLOW_TEST_SLOW=1 swift test > $(TEST_LOG) 2>&1; \
	exit_code=$$?; \
	xc_pass=`grep -c '^Test Case.*passed' $(TEST_LOG) || true`; \
	xc_fail=`grep -c '^Test Case.*failed' $(TEST_LOG) || true`; \
	st_fail=`grep -c '^✘ Test .* failed' $(TEST_LOG) || true`; \
	st_line=`grep 'Test run with' $(TEST_LOG) || true`; \
	st_total=`echo "$$st_line" | sed -n 's/.*with \([0-9]*\) tests.*/\1/p'`; \
	st_total=$${st_total:-0}; \
	xc_pass=$${xc_pass:-0}; \
	xc_fail=$${xc_fail:-0}; \
	st_fail=$${st_fail:-0}; \
	total=`expr $$xc_pass + $$xc_fail + $$st_total`; \
	fail=`expr $$xc_fail + $$st_fail`; \
	echo ""; \
	if [ $$exit_code -ne 0 ] || [ $$fail -ne 0 ]; then \
		echo "── FAILURES ──"; \
		grep -E '✘ Test |✘ Suite |^Test Case.*failed' $(TEST_LOG) | head -20; \
		echo ""; \
	fi; \
	echo "── Combined: $$total tests (`expr $$xc_pass + $$xc_fail` XCTest + $$st_total Swift Testing), $$fail failures ──"; \
	echo "Full log: $(TEST_LOG)"; \
	exit $$exit_code

# Clean build artifacts
clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean 2>/dev/null || true
	cd FreeFlowKit && swift package clean
	rm -rf DerivedData build

# Open in Xcode (generates project first if missing)
xcode: $(PROJECT)
	open $(PROJECT)

# Generate the project if it doesn't exist
$(PROJECT): project.yml
	$(MAKE) generate

# ---------------------------------------------------------------------------
# Release pipeline: archive → sign → dmg → notarize → staple → appcast
# ---------------------------------------------------------------------------

# Full release pipeline. Sub-makes preserve this order even under `make -j`.
release:
	@$(MAKE) archive
	@$(MAKE) sign
	@$(MAKE) dmg
	@$(MAKE) notarize
	@$(MAKE) appcast
	@echo ""
	@echo "══════════════════════════════════════════════════"
	@echo "  Release complete!"
	@echo "  DMG:     $(DMG_PATH)"
	@echo "  Appcast: $(RELEASE_DIR)/appcast.xml"
	@echo "══════════════════════════════════════════════════"

# Archive a Release build and export the app
archive: model-venv $(PROJECT)
	@echo "── Archiving Release build ──"
	$(MODEL_PYTHON) scripts/download-models.py --run \
		xcodebuild $(XCODE_FLAGS) -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Release -archivePath $(ARCHIVE_PATH) \
		CODE_SIGNING_ALLOWED=NO archive
	@echo "── Extracting app from archive ──"
	@rm -rf $(APP_PATH)
	@cp -R "$(ARCHIVE_PATH)/Products/Applications/FreeFlow.app" $(APP_PATH)
	@$(MAKE) verify-app-models APP_PATH="$(APP_PATH)"

# Sign the app bundle with hardened runtime and entitlements.
# Sparkle embeds XPC services and a nested Updater.app that must be
# signed inside-out: innermost bundles first, then the framework, then
# the outer app. codesign --deep cannot handle this reliably.
sign:
	@echo "── Stripping extended attributes before signing ──"
	xattr -cr $(APP_PATH)
	@echo "── Signing Sparkle nested components ──"
	@set -e; \
	SPARKLE_FW="$(APP_PATH)/Contents/Frameworks/Sparkle.framework/Versions/B"; \
	for xpc in "$$SPARKLE_FW/XPCServices/Installer.xpc" \
	           "$$SPARKLE_FW/XPCServices/Downloader.xpc"; do \
		if [ -d "$$xpc" ]; then \
			echo "  Signing $$xpc"; \
			codesign --force --options runtime --sign "$(SIGN_IDENTITY)" $(KEYCHAIN_FLAGS) --timestamp "$$xpc"; \
		fi; \
	done; \
	if [ -d "$$SPARKLE_FW/Updater.app" ]; then \
		echo "  Signing $$SPARKLE_FW/Updater.app"; \
		codesign --force --options runtime --sign "$(SIGN_IDENTITY)" $(KEYCHAIN_FLAGS) --timestamp "$$SPARKLE_FW/Updater.app"; \
	fi; \
	if [ -f "$$SPARKLE_FW/Autoupdate" ]; then \
		echo "  Signing $$SPARKLE_FW/Autoupdate"; \
		codesign --force --options runtime --sign "$(SIGN_IDENTITY)" $(KEYCHAIN_FLAGS) --timestamp "$$SPARKLE_FW/Autoupdate"; \
	fi
	@echo "── Signing Sparkle framework ──"
	codesign --force --options runtime \
		--sign "$(SIGN_IDENTITY)" \
		$(KEYCHAIN_FLAGS) \
		--timestamp \
		"$(APP_PATH)/Contents/Frameworks/Sparkle.framework/Versions/B"
	@echo "── Signing app bundle ──"
	codesign --force --options runtime \
		--sign "$(SIGN_IDENTITY)" \
		$(KEYCHAIN_FLAGS) \
		--entitlements FreeFlowApp/FreeFlow.entitlements \
		--timestamp \
		$(APP_PATH)
	@echo "── Verifying signature ──"
	codesign --verify --deep --strict --verbose=2 $(APP_PATH)

# Create a DMG with the signed app and an Applications symlink
dmg:
	@echo "── Creating DMG ──"
	@rm -rf $(DMG_STAGING)
	@mkdir -p $(DMG_STAGING)
	@cp -R $(APP_PATH) $(DMG_STAGING)/
	@ln -s /Applications $(DMG_STAGING)/Applications
	@mkdir -p $(RELEASE_DIR)
	@rm -f $(DMG_PATH)
	hdiutil create -volname "FreeFlow" -srcfolder $(DMG_STAGING) -ov -format UDZO $(DMG_PATH)
	@rm -rf $(DMG_STAGING)
	@echo "  $(DMG_PATH) ($$(du -h $(DMG_PATH) | cut -f1))"

# Submit DMG to Apple notarization and staple the ticket
notarize:
	@echo "── Submitting DMG to Apple notarization ──"
	xcrun notarytool submit $(DMG_PATH) \
		--keychain-profile "$(NOTARIZE_PROFILE)" \
		--wait
	@echo "── Stapling notarization ticket to DMG ──"
	xcrun stapler staple $(DMG_PATH)
	@echo "  $(DMG_PATH) ($$(du -h $(DMG_PATH) | cut -f1))"
	@echo "── Verifying Gatekeeper approval ──"
	@# DMGs are notarized but not code-signed. Verify the app inside.
	hdiutil attach $(DMG_PATH) -nobrowse -quiet
	spctl --assess --type execute --verbose=2 /Volumes/FreeFlow/FreeFlow.app
	hdiutil detach /Volumes/FreeFlow -quiet

# Generate or update appcast.xml from the release DMG.
# Locally, generate_appcast reads the EdDSA key from the Keychain.
# In CI, set SPARKLE_KEY env var and the key is piped via --ed-key-file -.
appcast:
ifeq ($(SPARKLE_BIN),)
	$(error "Sparkle tools not found. Run 'make build' first to fetch the Sparkle package.")
endif
	@echo "── Generating appcast ──"
	@if [ -n "$$SPARKLE_KEY" ]; then \
		echo "$$SPARKLE_KEY" | "$(SPARKLE_BIN)/generate_appcast" \
			--ed-key-file - \
			--download-url-prefix "$(DOWNLOAD_URL)" \
			-o $(RELEASE_DIR)/appcast.xml \
			$(RELEASE_DIR); \
	else \
		"$(SPARKLE_BIN)/generate_appcast" \
			--download-url-prefix "$(DOWNLOAD_URL)" \
			-o $(RELEASE_DIR)/appcast.xml \
			$(RELEASE_DIR); \
	fi
	@echo "  $(RELEASE_DIR)/appcast.xml"

# Print the version from Info.plist (used by CI)
version:
	@/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" FreeFlowApp/Info.plist
