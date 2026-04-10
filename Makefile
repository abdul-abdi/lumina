.PHONY: build release sign test test-integration clean run

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
