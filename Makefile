SHELL := /bin/bash

ROOT_DIR := $(abspath .)
BUILD_DIR := $(ROOT_DIR)/build
APP := $(BUILD_DIR)/usdtweak.app

.PHONY: build run clean

build:
	@bash "$(ROOT_DIR)/build.sh"

run:
	@[ -d "$(APP)" ] || { echo "Run 'make build' first."; exit 1; }
	@PXR_PLUGINPATH_NAME="$(APP)/Contents/plugin/usd" CYCLES_DEVICE=METAL open "$(APP)"

clean:
	rm -rf "$(ROOT_DIR)/source" "$(ROOT_DIR)/build" "$(ROOT_DIR)/deps"
	@echo "Cleaned."
