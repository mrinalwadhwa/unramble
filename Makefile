.PHONY: build run test test-ci test-os test-inventory test-all test-runner-tests clean xcode generate models \
	verify-models verify-app-models release archive sign notarize appcast version

# XcodeGen must be installed: brew install xcodegen
XCODEGEN := $(shell command -v xcodegen 2>/dev/null)
PROJECT  := Unramble.xcodeproj
SCHEME   := UnrambleApp
CONFIG   := Debug
XCODE_FLAGS := -skipPackagePluginValidation
PYTHON ?= python3
MODEL_TOOL := scripts/models.sh

# Release settings
TEAM_ID          := U5Y82TZF5K
SIGN_IDENTITY    := Developer ID Application: Mrinal Wadhwa ($(TEAM_ID))
NOTARIZE_PROFILE := unramble-notarize
ARCHIVE_PATH     := build/Unramble.xcarchive
APP_PATH         := build/Unramble.app
RELEASE_DIR      := releases
DMG_NAME         := Unramble.dmg
DMG_PATH         := $(RELEASE_DIR)/$(DMG_NAME)
DMG_STAGING      := build/dmg_contents
DOWNLOAD_URL     := https://github.com/mrinalwadhwa/unramble/releases/latest/download/
SPARKLE_BIN      := $(shell find ~/Library/Developer/Xcode/DerivedData/Unramble-*/SourcePackages/artifacts/sparkle/Sparkle/bin -maxdepth 0 2>/dev/null | head -1)

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

# `make models` is the only model-related target that uses the network.
models: $(MODEL_TOOL)
	@PYTHON="$(PYTHON)" "$(MODEL_TOOL)" download

# Verify the complete model pack without network access.
verify-models: $(MODEL_TOOL)
	@"$(MODEL_TOOL)" verify

# Verify the model pack copied into an extracted app archive.
verify-app-models: $(MODEL_TOOL)
	@"$(MODEL_TOOL)" verify "$(APP_PATH)/Contents/Resources/models"

# Generate training data from YAML, then train a LoRA adapter
train:
	@cd training && python3 generate_training_data.py --no-casual --split
	@cd training && python3 -u -m mlx_lm.lora --config lora-config.yaml

# Build the app after an offline model-pack verification.
build: verify-models $(PROJECT)
	xcodebuild $(XCODE_FLAGS) -project $(PROJECT) -scheme $(SCHEME) \
		-configuration $(CONFIG) build

# Build and launch
run: build
	@open "$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -showBuildSettings 2>/dev/null | grep -m1 ' BUILT_PRODUCTS_DIR' | awk '{print $$3}')/Unramble.app"

# Run the default package selection with collision-free durable artifacts.
test:
	@"scripts/run-tests.sh" default

# Run the bounded, clean-checkout CI selection without secrets or external test services.
test-ci:
	@"scripts/run-tests.sh" ci

# Run the host and OS-adapter suites (CoreAudio devices, CGEvent taps, the main
# run loop, system sounds) in their own target. They degrade gracefully when a
# resource is absent, so this lane is safe on a headless runner.
test-os:
	@"scripts/run-tests.sh" os

# Fail closed when the discovered test-suite set drifts from the committed
# inventory, so a new suite must be assigned to a lane before it can land.
test-inventory:
	@"scripts/check-test-inventory.sh" check

# Enable Keychain suites. Live, model, and evaluation gates are unchanged.
test-all:
	@"scripts/run-tests.sh" keychain

# Exercise the result parser and runner without building the Swift package.
test-runner-tests:
	@"scripts/test-runner-tests.sh"

# Clean build artifacts
clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean 2>/dev/null || true
	cd UnrambleKit && swift package clean
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

# Archive a Release build and export the app after offline verification.
archive: verify-models $(PROJECT)
	@echo "── Archiving Release build ──"
	xcodebuild $(XCODE_FLAGS) -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Release -archivePath $(ARCHIVE_PATH) \
		CODE_SIGNING_ALLOWED=NO archive
	@echo "── Extracting app from archive ──"
	@rm -rf $(APP_PATH)
	@cp -R "$(ARCHIVE_PATH)/Products/Applications/Unramble.app" $(APP_PATH)
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
		--entitlements UnrambleApp/Unramble.entitlements \
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
	hdiutil create -volname "Unramble" -srcfolder $(DMG_STAGING) -ov -format UDZO $(DMG_PATH)
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
	spctl --assess --type execute --verbose=2 /Volumes/Unramble/Unramble.app
	hdiutil detach /Volumes/Unramble -quiet

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
	@/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" UnrambleApp/Info.plist
