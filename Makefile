BIN        := dyntile
APP        := $(BIN).app
PREFIX     ?= $(HOME)/.local
APPDIR     ?= /Applications
CONFIG     ?= $(HOME)/.config/dyntile/dyntile.conf
# Ad-hoc ("-") signing means macOS treats every rebuild as a new app and drops the
# Accessibility grant. `make signing-cert` creates a stable self-signed identity;
# build with SIGN_ID=dyntile-local to use it.
SIGN_ID    ?= -
CERT_CN    ?= dyntile-local
KEYCHAIN   ?= $(HOME)/Library/Keychains/login.keychain-db

.PHONY: icon build release signing-cert release-universal test bundle install install-config uninstall run clean check reset-permission

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
	@if [ "$(SIGN_ID)" != "-" ] && \
	    ! security find-identity -v -p codesigning | grep -qF '$(SIGN_ID)'; then \
		echo; \
		echo "error: no codesigning identity named '$(SIGN_ID)' in your keychain."; \
		echo "  SIGN_ID selects an identity, it does not create one."; \
		echo "  run 'make signing-cert' to make one, or drop SIGN_ID to sign ad-hoc."; \
		echo; \
		exit 1; \
	fi
	codesign --force --sign "$(SIGN_ID)" --options runtime --timestamp=none $(APP)
	@echo "built $(APP), signed by $(SIGN_ID)"

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

# A self-signed code signing identity, so the app keeps one identity across rebuilds and
# macOS keeps honouring its Accessibility grant. Everything stays in your login keychain;
# macOS will ask you to authorise the trust setting, and codesign will ask once for
# access to the key (choose "Always Allow").
signing-cert:
	@if security find-identity -v -p codesigning | grep -qF '$(CERT_CN)'; then \
		echo "identity '$(CERT_CN)' already exists — build with SIGN_ID=\"$(CERT_CN)\""; \
		exit 0; \
	fi
	@tmp=$$(mktemp -d) && \
	openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
		-keyout $$tmp/key.pem -out $$tmp/cert.pem -subj "/CN=$(CERT_CN)" \
		-addext "basicConstraints=critical,CA:false" \
		-addext "keyUsage=critical,digitalSignature" \
		-addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null && \
	openssl pkcs12 -export -inkey $$tmp/key.pem -in $$tmp/cert.pem \
		-name "$(CERT_CN)" -out $$tmp/id.p12 -passout pass: && \
	security import $$tmp/id.p12 -k "$(KEYCHAIN)" -P "" -T /usr/bin/codesign && \
	security add-trusted-cert -r trustRoot -p codeSign -k "$(KEYCHAIN)" $$tmp/cert.pem && \
	rm -rf $$tmp && \
	echo && echo "created '$(CERT_CN)'. now run: make install SIGN_ID=\"$(CERT_CN)\""

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
