APP_NAME := Sparkle
BUILD_DIR := .build/release
APP_DIR := outputs/$(APP_NAME).app
DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
MODULE_CACHE := $(CURDIR)/.build/module-cache

.PHONY: build bundle run clean

build:
	DEVELOPER_DIR="$(DEVELOPER_DIR)" CLANG_MODULE_CACHE_PATH="$(MODULE_CACHE)" SWIFTPM_MODULECACHE_OVERRIDE="$(MODULE_CACHE)" swift build --disable-sandbox -c release

bundle: build
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	mkdir -p "$(APP_DIR)/Contents/Resources"
	cp "$(BUILD_DIR)/$(APP_NAME)" "$(APP_DIR)/Contents/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	cp Resources/SparkleIcon.png "$(APP_DIR)/Contents/Resources/SparkleIcon.png"
	cp -R Resources/Mascot "$(APP_DIR)/Contents/Resources/Mascot"
	codesign --force --deep --sign - "$(APP_DIR)"

run: bundle
	open "$(APP_DIR)"

clean:
	swift package clean
	rm -rf "$(APP_DIR)"
