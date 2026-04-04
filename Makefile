.PHONY: build release sign test clean run

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

# Run tests (unit tests don't need entitlements)
test:
	swift test

# Build, sign, and run with arguments: make run ARGS="echo hello"
run: build
	$(BINARY_DEBUG) run $(ARGS)

# Install to /usr/local/bin
install: release
	install -m 755 $(BINARY_RELEASE) /usr/local/bin/lumina

clean:
	swift package clean
	rm -rf .build
