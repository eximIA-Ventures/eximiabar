# exímIABar — build & install
#
# Targets:
#   make build        Build the universal signed .app into dist/ (Scripts/package_app.sh)
#   make icon         Regenerate AppIcon.icns from the source PNG
#   make install      Copy dist/ExímIABar.app into /Applications/ (may need sudo)
#   make install-user Copy dist/ExímIABar.app into ~/Applications/ (no sudo)
#   make uninstall    Remove /Applications/ExímIABar.app (may need sudo)
#   make clean        Remove dist/ and .build/
#   make test         Run swift test
#
# NOTE: the `install` target requires write access to /Applications — run with
#       sudo or ensure permissions. `install-user` is the sudo-free opt-in.

APP_NAME      := ExímIABar
DIST_APP      := dist/$(APP_NAME).app
INSTALL_DIR   := /Applications
USER_DIR      := $(HOME)/Applications
INSTALLED     := $(INSTALL_DIR)/$(APP_NAME).app
USER_INSTALLED := $(USER_DIR)/$(APP_NAME).app

.DEFAULT_GOAL := build
.PHONY: build icon install install-user uninstall clean test help

build:
	@./Scripts/package_app.sh

icon:
	@./Scripts/generate_icon.sh

install: build
	@rm -rf "$(INSTALLED)"
	@cp -R "$(DIST_APP)" "$(INSTALL_DIR)/" 2>/dev/null || \
	  (echo "⚠ Permission denied writing to $(INSTALL_DIR). Try: sudo make install" && exit 1)
	@echo "Installed: $(INSTALLED)"

install-user: build
	@mkdir -p "$(USER_DIR)"
	@rm -rf "$(USER_INSTALLED)"
	@cp -R "$(DIST_APP)" "$(USER_DIR)/"
	@echo "Installed: $(USER_INSTALLED)"

uninstall:
	@rm -rf "$(INSTALLED)" 2>/dev/null || \
	  (echo "⚠ Permission denied removing from $(INSTALL_DIR). Try: sudo make uninstall" && exit 1)
	@echo "Uninstalled: $(INSTALLED)"

clean:
	@rm -rf dist .build
	@echo "Cleaned: dist/ and .build/"

test:
	@swift test

help:
	@echo "exímIABar make targets:"
	@echo "  build         Build universal signed .app into dist/"
	@echo "  icon          Regenerate AppIcon.icns"
	@echo "  install       Copy app to /Applications/ (may need sudo)"
	@echo "  install-user  Copy app to ~/Applications/ (no sudo)"
	@echo "  uninstall     Remove app from /Applications/ (may need sudo)"
	@echo "  clean         Remove dist/ and .build/"
	@echo "  test          Run swift test"
