# ==============================================================================
# My LLM GUI – Makefile
# ==============================================================================

APP_NAME        := My LLM
BUNDLE_NAME     := My\ LLM.app
BINARY_NAME     := myllm-gui
BUNDLE_ID       := jp.emotiongraphics.myllm

BUILD_DIR       := build
RELEASE_DIR     := release
BUNDLE_DIR      := $(RELEASE_DIR)/My LLM.app
MACOS_DIR       := $(BUNDLE_DIR)/Contents/MacOS
RESOURCES_DIR   := $(BUNDLE_DIR)/Contents/Resources
BUILD_BINARY    := $(BUILD_DIR)/$(BINARY_NAME)
BIN_DIR         := $(RESOURCES_DIR)/bin

# App version (used for ZIP filename)
VERSION         := 1.0.0

# Dependency versions
JQ_VERSION          := 1.8.1
WHICHLANG_VERSION   := 0.1.1

JQ_URL_ARM64        := https://github.com/jqlang/jq/releases/download/jq-$(JQ_VERSION)/jq-macos-arm64
JQ_URL_AMD64        := https://github.com/jqlang/jq/releases/download/jq-$(JQ_VERSION)/jq-macos-amd64
WHICHLANG_URL_ARM64 := https://github.com/rinodrops/whichlang-cli/releases/download/v$(WHICHLANG_VERSION)/whichlang-cli-$(WHICHLANG_VERSION)-darwin-arm64.tar.gz
WHICHLANG_URL_AMD64 := https://github.com/rinodrops/whichlang-cli/releases/download/v$(WHICHLANG_VERSION)/whichlang-cli-$(WHICHLANG_VERSION)-darwin-amd64.tar.gz
MYLLM_BASE_URL      := https://raw.githubusercontent.com/rinodrops/myllm-cli/main

ZIP_OUT         := $(RELEASE_DIR)/My LLM-$(VERSION).zip

.PHONY: all build build-universal bundle sign notarize notary-setup dist zip clean

# Default: just compile the binary (fast iteration during development)
all: build

# Full distribution pipeline: bundle → sign → notarize → zip
dist: bundle sign notarize zip

# Compile current-arch binary (fast iteration during development)
build:
	@mkdir -p "$(BUILD_DIR)"
	swiftc -O -o $(BUILD_BINARY) MyllmGui.swift

# Compile universal binary (arm64 + x86_64) for distribution
build-universal:
	@mkdir -p "$(BUILD_DIR)"
	swiftc -O -target arm64-apple-macos13.0 -o "$(BUILD_DIR)/$(BINARY_NAME)-arm64" MyllmGui.swift
	swiftc -O -target x86_64-apple-macos13.0 -o "$(BUILD_DIR)/$(BINARY_NAME)-amd64" MyllmGui.swift
	lipo -create -output $(BUILD_BINARY) \
		"$(BUILD_DIR)/$(BINARY_NAME)-arm64" \
		"$(BUILD_DIR)/$(BINARY_NAME)-amd64"
	@rm "$(BUILD_DIR)/$(BINARY_NAME)-arm64" "$(BUILD_DIR)/$(BINARY_NAME)-amd64"

# Build the full .app bundle (universal)
bundle: build-universal
	@echo "==> Creating bundle structure"
	@mkdir -p "$(MACOS_DIR)" "$(BIN_DIR)"

	@echo "==> Copying binary"
	@cp $(BUILD_BINARY) "$(MACOS_DIR)/$(APP_NAME)"
	@chmod 755 "$(MACOS_DIR)/$(APP_NAME)"

	@echo "==> Writing Info.plist"
	@cp Info.plist "$(BUNDLE_DIR)/Contents/Info.plist"

	@echo "==> Copying app icon (if present)"
	@if [ -f AppIcon.icns ]; then \
		mkdir -p "$(RESOURCES_DIR)"; \
		cp AppIcon.icns "$(RESOURCES_DIR)/AppIcon.icns"; \
	fi

	@echo "==> Downloading myllm script"
	@curl -fsSL "$(MYLLM_BASE_URL)/myllm" -o "$(BIN_DIR)/myllm"
	@chmod 755 "$(BIN_DIR)/myllm"

	@echo "==> Downloading starter config template"
	@curl -fsSL "$(MYLLM_BASE_URL)/config/config.toml" -o "$(RESOURCES_DIR)/config.toml"

	@echo "==> Downloading jq $(JQ_VERSION) (universal)"
	@curl -fsSL "$(JQ_URL_ARM64)" -o "$(BUILD_DIR)/jq-arm64"
	@curl -fsSL "$(JQ_URL_AMD64)" -o "$(BUILD_DIR)/jq-amd64"
	@lipo -create -output "$(BIN_DIR)/jq" "$(BUILD_DIR)/jq-arm64" "$(BUILD_DIR)/jq-amd64"
	@rm "$(BUILD_DIR)/jq-arm64" "$(BUILD_DIR)/jq-amd64"
	@chmod 755 "$(BIN_DIR)/jq"

	@echo "==> Downloading whichlang-cli $(WHICHLANG_VERSION) (universal)"
	@mkdir -p /tmp/whichlang-arm64 /tmp/whichlang-amd64
	@curl -fsSL "$(WHICHLANG_URL_ARM64)" -o /tmp/whichlang-arm64.tar.gz
	@curl -fsSL "$(WHICHLANG_URL_AMD64)" -o /tmp/whichlang-amd64.tar.gz
	@tar -xzf /tmp/whichlang-arm64.tar.gz -C /tmp/whichlang-arm64
	@tar -xzf /tmp/whichlang-amd64.tar.gz -C /tmp/whichlang-amd64
	@WLARM64=$$(find /tmp/whichlang-arm64 -maxdepth 2 -type f | head -1) && \
	 WLAMD64=$$(find /tmp/whichlang-amd64 -maxdepth 2 -type f | head -1) && \
	 lipo -create -output "$(BIN_DIR)/whichlang-cli" "$$WLARM64" "$$WLAMD64"
	@chmod 755 "$(BIN_DIR)/whichlang-cli"
	@rm -rf /tmp/whichlang-arm64 /tmp/whichlang-amd64 /tmp/whichlang-arm64.tar.gz /tmp/whichlang-amd64.tar.gz

	@echo "==> Bundle ready: $(RELEASE_DIR)/My LLM.app"

# Sign the .app bundle
# Requires: APPLE_DEVELOPER_CERTIFICATE_NAME env var
sign:
	@test -d "$(RELEASE_DIR)/My LLM.app" || (echo "Error: run 'make bundle' first" && exit 1)
	@echo "==> Signing bundled binaries"
	@codesign --force --verify --verbose \
		--sign "$$APPLE_DEVELOPER_CERTIFICATE_NAME" \
		--options runtime \
		"$(BIN_DIR)/jq"
	@codesign --force --verify --verbose \
		--sign "$$APPLE_DEVELOPER_CERTIFICATE_NAME" \
		--options runtime \
		"$(BIN_DIR)/whichlang-cli"
	@echo "==> Signing app bundle"
	@codesign --force --verify --verbose \
		--sign "$$APPLE_DEVELOPER_CERTIFICATE_NAME" \
		--options runtime \
		--entitlements entitlements.plist \
		"$(RELEASE_DIR)/My LLM.app"
	@echo "==> Verifying signature"
	@codesign --verify --deep --strict --verbose=2 "$(RELEASE_DIR)/My LLM.app"
	@echo "==> Signing complete"

# Notarize and staple the signed .app
# Requires: APPLE_DEVELOPER_KEYCHAIN_PROFILE env var (set up once with 'make notary-setup')
notarize:
	@test -d "$(RELEASE_DIR)/My LLM.app" || (echo "Error: run 'make bundle' and 'make sign' first" && exit 1)
	@echo "==> Creating archive for notarization"
	@ditto -c -k --keepParent "$(RELEASE_DIR)/My LLM.app" "$(RELEASE_DIR)/My LLM.zip"
	@echo "==> Submitting for notarization (this may take a few minutes)"
	@xcrun notarytool submit "$(RELEASE_DIR)/My LLM.zip" \
		--keychain-profile "$$APPLE_DEVELOPER_KEYCHAIN_PROFILE" \
		--wait
	@echo "==> Stapling notarization ticket"
	@xcrun stapler staple "$(RELEASE_DIR)/My LLM.app"
	@rm -f "$(RELEASE_DIR)/My LLM.zip"
	@echo "==> Verifying Gatekeeper acceptance"
	@spctl --assess --type exec --verbose "$(RELEASE_DIR)/My LLM.app"
	@echo "==> Done: $(RELEASE_DIR)/My LLM.app is signed and notarized"

# One-time setup: store notarization credentials in the Keychain
# Requires: APPLE_ID, APPLE_DEVELOPER_TEAM_ID, APPLE_DEVELOPER_KEYCHAIN_PROFILE,
#           APPLE_DEVELOPER_APP_PASSWORD env vars
notary-setup:
	xcrun notarytool store-credentials "$$APPLE_DEVELOPER_KEYCHAIN_PROFILE" \
		--apple-id "$$APPLE_ID" \
		--team-id "$$APPLE_DEVELOPER_TEAM_ID" \
		--password "$$APPLE_DEVELOPER_APP_PASSWORD"

# Create a distributable ZIP
# The notarization ticket is stapled to the .app, so no separate ZIP notarization needed
# Requires: signed and notarized release/My LLM.app
zip:
	@test -d "$(RELEASE_DIR)/My LLM.app" || \
		(echo "Error: run 'make bundle', 'make sign', and 'make notarize' first" && exit 1)
	@echo "==> Creating ZIP archive"
	@rm -f "$(ZIP_OUT)"
	@ditto -c -k --keepParent "$(RELEASE_DIR)/My LLM.app" "$(ZIP_OUT)"
	@echo "==> Done: $(ZIP_OUT)"


clean:
	rm -rf $(BUILD_DIR) $(RELEASE_DIR)
