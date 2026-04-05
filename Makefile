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

# Run e2e integration tests via the actual CLI (requires VM image + jq)
test-integration: build
	@echo "=== e2e: echo hello ==="
	@$(BINARY_DEBUG) run "echo hello" | jq -e '.stdout == "hello\n"' >/dev/null && echo "PASS" || (echo "FAIL"; exit 1)
	@echo "=== e2e: exit code ==="
	@$(BINARY_DEBUG) run "exit 42" 2>/dev/null; test $$? -eq 42 && echo "PASS" || (echo "FAIL: expected exit 42"; exit 1)
	@echo "=== e2e: stderr ==="
	@$(BINARY_DEBUG) run "echo err >&2" | jq -e '.stderr | test("err")' >/dev/null && echo "PASS" || (echo "FAIL: stderr not captured"; exit 1)
	@echo "=== e2e: uname ==="
	@$(BINARY_DEBUG) run "uname -m" | jq -e '.stdout == "aarch64\n"' >/dev/null && echo "PASS" || (echo "FAIL"; exit 1)
	@echo "=== e2e: upload + read ==="
	@echo "upload-test" > /tmp/lumina-e2e-upload.txt
	@$(BINARY_DEBUG) run --copy "/tmp/lumina-e2e-upload.txt:/tmp/test.txt" "cat /tmp/test.txt" | jq -e '.stdout == "upload-test\n"' >/dev/null && echo "PASS" || (echo "FAIL"; exit 1)
	@echo "=== e2e: download ==="
	@rm -f /tmp/lumina-e2e-download.txt
	@$(BINARY_DEBUG) run --download "/etc/hostname:/tmp/lumina-e2e-download.txt" "true" >/dev/null 2>&1 && test -f /tmp/lumina-e2e-download.txt && echo "PASS" || (echo "FAIL: download file not created"; exit 1)
	@echo "All integration tests passed."

# Build, sign, and run with arguments: make run ARGS="echo hello"
run: build
	$(BINARY_DEBUG) run $(ARGS)

# Install to /usr/local/bin
install: release
	install -m 755 $(BINARY_RELEASE) /usr/local/bin/lumina

clean:
	swift package clean
	rm -rf .build
