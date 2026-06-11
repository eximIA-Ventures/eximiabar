# exímIABar — build & install
#
# Targets:
#   make build      Build the universal signed .app into dist/ (Scripts/package_app.sh)
#   make icon       Regenerate AppIcon.icns from the source PNG
#   make install    Copy dist/ExímIABar.app into ~/Applications/
#   make uninstall  Remove ~/Applications/ExímIABar.app
#   make clean      Remove dist/ and .build/
#   make test       Run swift test

APP_NAME    := ExímIABar
DIST_APP    := dist/$(APP_NAME).app
INSTALL_DIR := $(HOME)/Applications
INSTALLED   := $(INSTALL_DIR)/$(APP_NAME).app

.DEFAULT_GOAL := build
.PHONY: build icon install uninstall clean test help

build:
	@./Scripts/package_app.sh

icon:
	@./Scripts/generate_icon.sh

install: build
	@mkdir -p "$(INSTALL_DIR)"
	@rm -rf "$(INSTALLED)"
	@cp -R "$(DIST_APP)" "$(INSTALL_DIR)/"
	@echo "Installed: $(INSTALLED)"

uninstall:
	@rm -rf "$(INSTALLED)"
	@echo "Uninstalled: $(INSTALLED)"

clean:
	@rm -rf dist .build
	@echo "Cleaned: dist/ and .build/"

test:
	@swift test

help:
	@echo "exímIABar make targets:"
	@echo "  build      Build universal signed .app into dist/"
	@echo "  icon       Regenerate AppIcon.icns"
	@echo "  install    Copy app to ~/Applications/"
	@echo "  uninstall  Remove app from ~/Applications/"
	@echo "  clean      Remove dist/ and .build/"
	@echo "  test       Run swift test"
