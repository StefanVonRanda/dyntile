BIN        := dyntile
APP        := $(BIN).app
PREFIX     ?= $(HOME)/.local
APPDIR     ?= /Applications
CONFIG     ?= $(HOME)/.config/dyntile/dyntile.conf
# Set DYNTILE_SIGN_ID to a self-signed codesigning identity to keep the
# Accessibility grant across rebuilds. Falls back to ad-hoc signing.
SIGN_ID    ?= -

.PHONY: icon build release release-universal test bundle install install-config uninstall run clean check reset-permission

build:
	swift build

release:
	swift build -c release

# Universal binary, for sharing the build with an Intel Mac.
release-universal:
	swift build -c release --arch arm64 --arch x86_64

test: build
	.build/debug/$(BIN) --selftest

check: build
	.build/debug/$(BIN) --check

# A .app bundle keeps dyntile out of the Dock and gives it a stable identity
# for the Accessibility permission.
# The icon is drawn from source rather than checked in as a binary.
icon:
	swift Tools/MakeIcon.swift Resources

bundle: release icon
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build -c release --show-bin-path)/$(BIN)" $(APP)/Contents/MacOS/$(BIN)
	cp Resources/dyntile.conf $(APP)/Contents/Resources/dyntile.conf
	cp Resources/dyntile.icns $(APP)/Contents/Resources/dyntile.icns
	sed 's/@VERSION@/$(shell git describe --tags --always 2>/dev/null || echo dev)/' \
		Resources/Info.plist > $(APP)/Contents/Info.plist
	codesign --force --sign "$(SIGN_ID)" --options runtime --timestamp=none $(APP) 2>/dev/null \
		|| codesign --force --sign "$(SIGN_ID)" $(APP)
	@echo "built $(APP)"

install: bundle install-config
	rm -rf $(APPDIR)/$(APP)
	cp -R $(APP) $(APPDIR)/$(APP)
	mkdir -p $(PREFIX)/bin
	ln -sf $(APPDIR)/$(APP)/Contents/MacOS/$(BIN) $(PREFIX)/bin/$(BIN)
	@echo
	@echo "installed to $(APPDIR)/$(APP) (cli: $(PREFIX)/bin/$(BIN))"
	@echo "open $(APPDIR)/$(APP) once, then grant Accessibility in System Settings."

install-config:
	@mkdir -p $(dir $(CONFIG))
	@if [ -f "$(CONFIG)" ]; then \
		echo "keeping existing $(CONFIG)"; \
	else \
		cp Resources/dyntile.conf "$(CONFIG)"; \
		echo "wrote $(CONFIG)"; \
	fi

# An ad-hoc signature changes on every rebuild, which leaves a stale Accessibility
# entry that macOS will not match. This clears it so the prompt comes back clean.
reset-permission:
	tccutil reset Accessibility com.igzo.dyntile
	@echo "now relaunch dyntile.app and accept the prompt"

uninstall:
	rm -rf $(APPDIR)/$(APP) $(PREFIX)/bin/$(BIN)

run: build
	.build/debug/$(BIN) -v

clean:
	rm -rf .build $(APP)
