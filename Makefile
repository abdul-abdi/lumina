.PHONY: build release sign test test-integration test-desktop clean run dev-app doctor-signing

BINARY_DEBUG = $(shell swift build --show-bin-path)/lumina
BINARY_RELEASE = $(shell swift build -c release --show-bin-path)/lumina
ENTITLEMENTS = lumina.entitlements

# Build debug + codesign with entitlements (one command, always works)
build:
	swift build
	codesign --entitlements $(ENTITLEMENTS) --force -s - $(BINARY_DEBUG)
	@echo "Built and signed: $(BINARY_DEBUG)"

# Build release + codesign
release:
	swift build -c release
	codesign --entitlements $(ENTITLEMENTS) --force -s - $(BINARY_RELEASE)
	@echo "Built and signed: $(BINARY_RELEASE)"

# Sign an already-built binary (useful after swift build)
sign:
	codesign --entitlements $(ENTITLEMENTS) --force -s - $(BINARY_DEBUG)

# Run unit tests (no entitlements needed)
test:
	swift test

# Run comprehensive e2e test suite via the actual CLI (requires VM image + jq)
test-integration: build
	@bash tests/e2e.sh $(BINARY_DEBUG)

# v0.7.0 M3 — desktop (EFI) boot smoke test against a small Alpine ARM64 ISO.
# Requires network on first run to fetch the ISO; caches under ~/.lumina/cache/.
test-desktop: build
	@bash tests/desktop.sh

# Run quick smoke tests only (subset of e2e, faster)
test-smoke: build
	@echo "=== smoke: echo hello ==="
	@$(BINARY_DEBUG) run "echo hello" | jq -e '.stdout == "hello\n"' >/dev/null && echo "PASS" || (echo "FAIL"; exit 1)
	@echo "=== smoke: exit code ==="
	@$(BINARY_DEBUG) run "exit 42" 2>/dev/null; test $$? -eq 42 && echo "PASS" || (echo "FAIL: expected exit 42"; exit 1)
	@echo "=== smoke: stderr ==="
	@$(BINARY_DEBUG) run "echo err >&2" | jq -e '.stderr | test("err")' >/dev/null && echo "PASS" || (echo "FAIL: stderr not captured"; exit 1)
	@echo "All smoke tests passed."

# Build, sign, and run with arguments: make run ARGS="echo hello"
run: build
	$(BINARY_DEBUG) run $(ARGS)

# Install (default: ~/.local, override: make install PREFIX=/usr/local)
PREFIX ?= $(HOME)/.local
install: release
	@mkdir -p $(PREFIX)/bin
	install -m 755 $(BINARY_RELEASE) $(PREFIX)/bin/lumina
	@echo "Installed to $(PREFIX)/bin/lumina"

clean:
	swift package clean
	rm -rf .build

# Build + install the desktop app using the first available developer
# signing identity (Apple Development / Personal Team / Developer ID).
# Enables NetworkMode.bridged by signing with the full entitlements set
# (com.apple.vm.networking) — required for VZBridgedNetworkDeviceAttachment
# on macOS 14+. Prerequisite: Xcode > Settings > Accounts > Apple ID.
# If no identity is found, prints setup instructions and exits.
dev-app:
	@IDENT=$$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application|Apple Distribution/ {print $$2; exit}'); \
	if [ -z "$$IDENT" ]; then \
		echo "error: no developer codesigning identity found."; \
		echo ""; \
		echo "Set up a free Personal Team (5 minutes):"; \
		echo "  1. Open Xcode, go to Settings > Accounts"; \
		echo "  2. Click + > Apple ID, sign in with any Apple ID"; \
		echo "  3. A 'Personal Team' is created automatically"; \
		echo "  4. Re-run: make dev-app"; \
		echo ""; \
		echo "Alternatively, \$$99/year Apple Developer Program gets you a"; \
		echo "Developer ID for distribution-grade signing + notarization."; \
		exit 2; \
	fi; \
	echo "→ Signing with: $$IDENT"; \
	LUMINA_SIGN_IDENTITY="$$IDENT" bash scripts/build-app.sh --install

# Inspect the local signing environment. Prints certs, Xcode teams,
# whether bridged networking is usable.
doctor-signing:
	@echo "=== Codesigning identities ==="
	@security find-identity -p codesigning -v 2>/dev/null || echo "(none)"
	@echo ""
	@echo "=== Team identifiers on codesigning certs ==="
	@security find-identity -p codesigning -v 2>/dev/null | grep -oE '\([A-Z0-9]+\)' | sort -u | tr -d '()' | sed 's/^/  /' || echo "  (none)"
	@echo ""
	@echo "=== Currently installed /Applications/Lumina.app entitlements ==="
	@codesign -d --entitlements - /Applications/Lumina.app 2>&1 | grep -E 'virtualization|hypervisor|networking|network.client' || echo "(Lumina.app not installed)"
	@echo ""
	@echo "=== NetworkMode.bridged availability ==="
	@if codesign -d --entitlements - /Applications/Lumina.app 2>&1 | grep -q 'com.apple.vm.networking'; then \
		echo "✓ bridged networking available (app signed with com.apple.vm.networking)"; \
	else \
		echo "✗ bridged networking NOT available — run 'make dev-app' after setting up Xcode Apple ID"; \
	fi
