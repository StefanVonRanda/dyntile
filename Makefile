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

.PHONY: icon build release signing-cert remove-signing-cert release-universal test bundle install install-config uninstall run clean check reset-permission

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
	@if [ "$(SIGN_ID)" != "-" ] && ! security find-identity | grep -qF '$(SIGN_ID)'; then \
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

# A self-signed code signing identity, so the app keeps ONE identity across rebuilds and
# macOS keeps honouring its Accessibility grant. The designated requirement codesign then
# writes is "certificate leaf = H\"...\"" rather than a cdhash, which is what survives a
# rebuild. The certificate is never marked as trusted: codesign does not need that, and
# not touching the trust store means no authorisation dialog.
#
# The key is imported as a traditional PKCS#1 PEM, not a PKCS#12 bundle: OpenSSL 3 writes
# PKCS#12 with an AES/PBKDF2 MAC that Apple's Security framework cannot read, which fails
# as "MAC verification failed during PKCS12 import (wrong password?)".
signing-cert:
	@if security find-identity | grep -qF '$(CERT_CN)'; then \
		echo "identity '$(CERT_CN)' already exists — build with SIGN_ID=\"$(CERT_CN)\""; \
		exit 0; \
	fi
	@set -e; tmp=$$(mktemp -d); trap 'rm -rf $$tmp' EXIT; \
	openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
		-keyout $$tmp/key.pem -out $$tmp/cert.pem -subj "/CN=$(CERT_CN)" \
		-addext "basicConstraints=critical,CA:false" \
		-addext "keyUsage=critical,digitalSignature" \
		-addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null; \
	openssl rsa -in $$tmp/key.pem -traditional -out $$tmp/rsa.pem 2>/dev/null \
		|| openssl rsa -in $$tmp/key.pem -out $$tmp/rsa.pem 2>/dev/null; \
	if ! grep -q "BEGIN RSA PRIVATE KEY" $$tmp/rsa.pem; then \
		echo "error: could not write a PKCS#1 key that macOS can import"; exit 1; \
	fi; \
	security import $$tmp/rsa.pem -k "$(KEYCHAIN)" -f openssl -t priv -T /usr/bin/codesign; \
	security import $$tmp/cert.pem -k "$(KEYCHAIN)" -f openssl -t cert -T /usr/bin/codesign; \
	echo; \
	echo "created '$(CERT_CN)' in $(KEYCHAIN)"; \
	echo "now run: make install SIGN_ID=\"$(CERT_CN)\""; \
	echo "codesign will ask once for access to the key — choose \"Always Allow\"."

# Remove the identity created by signing-cert.
remove-signing-cert:
	security delete-identity -c "$(CERT_CN)" "$(KEYCHAIN)"

# An ad-hoc signature changes on every rebuild, which leaves a stale Accessibility
# entry that macOS will not match. This clears it so the prompt comes back clean.
reset-permission:
	tccutil reset Accessibility io.github.stefanvonranda.dyntile
	@echo "now relaunch dyntile.app and accept the prompt"

uninstall:
	rm -rf $(APPDIR)/$(APP) $(PREFIX)/bin/$(BIN)

run: build
	.build/debug/$(BIN) -v

clean:
	rm -rf .build $(APP)
