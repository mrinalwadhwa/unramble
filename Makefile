.PHONY: build run test clean xcode generate release archive sign notarize appcast version linux-dev linux-test linux-build linux-package linux-install

# XcodeGen must be installed: brew install xcodegen
XCODEGEN := $(shell command -v xcodegen 2>/dev/null)
PROJECT  := FreeFlow.xcodeproj
SCHEME   := FreeFlowApp
CONFIG   := Debug

linux-dev:
	./scripts/dev-linux.sh

linux-test:
	./scripts/test-linux.sh

linux-build:
	./scripts/build-linux.sh

linux-package:
	./scripts/package-linux.sh

linux-install:
	./scripts/install-linux.sh

# Release settings
TEAM_ID          := 3A56YKKGA5
SIGN_IDENTITY    := Developer ID Application: Ockam Inc. ($(TEAM_ID))
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
# When set, codesign and xcodebuild use --keychain/OTHER_CODE_SIGN_FLAGS
# to find the signing identity. Leave unset for local builds (uses
# default keychain search list).
KEYCHAIN         ?=
ifdef KEYCHAIN
  KEYCHAIN_FLAGS := --keychain $(KEYCHAIN)
  XCODE_SIGN_FLAGS := OTHER_CODE_SIGN_FLAGS="--keychain $(KEYCHAIN)"
else
  KEYCHAIN_FLAGS :=
  XCODE_SIGN_FLAGS :=
endif

# Generate the Xcode project from project.yml
generate:
ifndef XCODEGEN
	$(error "xcodegen not found. Install with: brew install xcodegen")
endif
	xcodegen generate

# Build the app (generates project first if missing)
build: $(PROJECT)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) build

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

test:
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
test-all:
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

# Full release pipeline
release: archive sign dmg notarize appcast
	@echo ""
	@echo "══════════════════════════════════════════════════"
	@echo "  Release complete!"
	@echo "  DMG:     $(DMG_PATH)"
	@echo "  Appcast: $(RELEASE_DIR)/appcast.xml"
	@echo "══════════════════════════════════════════════════"

# Archive a Release build and export the app
archive: $(PROJECT)
	@echo "── Archiving Release build ──"
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-archivePath $(ARCHIVE_PATH) \
		CODE_SIGN_IDENTITY="$(SIGN_IDENTITY)" \
		DEVELOPMENT_TEAM=$(TEAM_ID) \
		ENABLE_HARDENED_RUNTIME=YES \
		$(XCODE_SIGN_FLAGS) \
		archive
	@echo "── Extracting app from archive ──"
	@rm -rf $(APP_PATH)
	@cp -R "$(ARCHIVE_PATH)/Products/Applications/FreeFlow.app" $(APP_PATH)

# Sign the app bundle with hardened runtime and entitlements.
# Sparkle embeds XPC services and a nested Updater.app that must be
# signed inside-out: innermost bundles first, then the framework, then
# the outer app. codesign --deep cannot handle this reliably.
sign:
	@echo "── Signing Sparkle nested components ──"
	@SPARKLE_FW="$(APP_PATH)/Contents/Frameworks/Sparkle.framework/Versions/B"; \
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
	@echo "── Stripping extended attributes ──"
	xattr -cr $(APP_PATH)

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
