.DEFAULT_GOAL := help
SHELL := /bin/bash

XCODEBUILD := xcodebuild -project Forge.xcodeproj -scheme Forge
BUILD_DIR := build/release
DIST_DIR := dist
APP_NAME := Forge.app
APP_PATH := $(BUILD_DIR)/Build/Products/Release/$(APP_NAME)
GHOSTTY_RELEASE_TAG := xcframework-bc0ee3142fe661f7342a9b76d712a417d59d5aae
GHOSTTY_ARCHIVE_URL := https://github.com/manaflow-ai/ghostty/releases/download/$(GHOSTTY_RELEASE_TAG)/GhosttyKit.xcframework.tar.gz
GHOSTTY_ARCHIVE_SHA256 := 073ea7f8ee5f889b3208365942373b53fa9cd71d0406d4599f7f15e43917394e
GHOSTTY_XCFRAMEWORK := Dependencies/GhosttyKit.xcframework
GHOSTTY_STAMP := $(GHOSTTY_XCFRAMEWORK)/.forge-$(GHOSTTY_RELEASE_TAG)

.PHONY: help deps project test build release demo lint format fmt clean can-release \
	_require-curl _require-shasum _require-tar _require-xcodebuild _require-xcodegen \
	_require-swiftformat _require-swiftlint

##@ Setup

deps: $(GHOSTTY_STAMP) ## Download pinned third-party dependencies

$(GHOSTTY_STAMP):
	@echo "==> Downloading GhosttyKit ($(GHOSTTY_RELEASE_TAG))..."
	@command -v curl >/dev/null || { echo "curl is required"; exit 1; }; \
	command -v shasum >/dev/null || { echo "shasum is required"; exit 1; }; \
	command -v tar >/dev/null || { echo "tar is required"; exit 1; }; \
	tmpdir="$$(mktemp -d)"; \
	archive="$$tmpdir/GhosttyKit.xcframework.tar.gz"; \
	curl --fail --location --silent --show-error "$(GHOSTTY_ARCHIVE_URL)" --output "$$archive"; \
	checksum="$$(shasum -a 256 "$$archive" | awk '{print $$1}')"; \
	if [ "$$checksum" != "$(GHOSTTY_ARCHIVE_SHA256)" ]; then \
		echo "ERROR: GhosttyKit checksum mismatch"; \
		echo "expected $(GHOSTTY_ARCHIVE_SHA256)"; \
		echo "actual   $$checksum"; \
		rm -rf "$$tmpdir"; \
		exit 1; \
	fi; \
	tar -xzf "$$archive" -C "$$tmpdir"; \
	if [ ! -d "$$tmpdir/GhosttyKit.xcframework" ]; then \
		echo "ERROR: GhosttyKit.xcframework missing from archive"; \
		rm -rf "$$tmpdir"; \
		exit 1; \
	fi; \
	rm -rf "$(GHOSTTY_XCFRAMEWORK)"; \
	mkdir -p Dependencies; \
	mv "$$tmpdir/GhosttyKit.xcframework" "$(GHOSTTY_XCFRAMEWORK)"; \
	touch "$(GHOSTTY_STAMP)"; \
	rm -rf "$$tmpdir"
	@echo "==> Ready: $(GHOSTTY_XCFRAMEWORK)"

project: $(GHOSTTY_STAMP) _require-xcodegen ## Regenerate the Xcode project from project.yml
	@xcodegen generate --quiet

##@ Development

test: project _require-xcodebuild ## Run current validation build (no XCTest bundle configured yet)
	@$(XCODEBUILD) -configuration Debug build

build: test ## Build the app in Debug configuration

release: project _require-xcodebuild ## Build the release app into dist/
	@echo "==> Building Release..."
	@$(XCODEBUILD) -configuration Release -derivedDataPath "$(BUILD_DIR)" -quiet
	@if [ ! -d "$(APP_PATH)" ]; then echo "ERROR: $(APP_NAME) not found at $(APP_PATH)"; exit 1; fi
	@echo "==> Built: $(APP_PATH)"
	@mkdir -p "$(DIST_DIR)"
	@rm -rf "$(DIST_DIR)/$(APP_NAME)"
	@cp -R "$(APP_PATH)" "$(DIST_DIR)/$(APP_NAME)"
	@echo "==> Copied to: $(DIST_DIR)/$(APP_NAME)"
	@echo "==> Done. Run with: open $(DIST_DIR)/$(APP_NAME)"

demo: project _require-xcodebuild ## Launch interactive demo mode for screenshots
	@bash scripts/demo.sh

clean: _require-xcodebuild ## Remove generated artifacts and clean Xcode outputs
	@rm -rf build dist
	@$(XCODEBUILD) clean

##@ Quality

lint: _require-swiftformat _require-swiftlint ## Run formatting and lint checks
	@swiftformat --lint .
	@swiftlint lint --strict

format: _require-swiftformat ## Apply Swift formatting
	@swiftformat .

fmt: format ## Alias for format

can-release: lint test release ## Run the full pre-release verification suite

##@ Help

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_\-\/]+:.*?##/ { printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

_require-curl:
	@command -v curl >/dev/null || { echo "curl is required"; exit 1; }

_require-shasum:
	@command -v shasum >/dev/null || { echo "shasum is required"; exit 1; }

_require-tar:
	@command -v tar >/dev/null || { echo "tar is required"; exit 1; }

_require-xcodebuild:
	@command -v xcodebuild >/dev/null || { echo "xcodebuild is required"; exit 1; }

_require-xcodegen:
	@command -v xcodegen >/dev/null || { echo "xcodegen is required"; exit 1; }

_require-swiftformat:
	@command -v swiftformat >/dev/null || { echo "swiftformat is required"; exit 1; }

_require-swiftlint:
	@command -v swiftlint >/dev/null || { echo "swiftlint is required"; exit 1; }
