#!/usr/bin/env bash
# scripts/build-app.sh — build Lumina.app via SPM (no Xcode required).
#
# Produces a code-signed, runnable .app bundle at .build/Lumina.app.
# Pass --install to also copy it to /Applications and launch.
#
# v0.7.0 ships ad-hoc signed (no Apple Dev account needed). To produce a
# notarizable build later: set LUMINA_SIGN_IDENTITY="Developer ID Application: ..."
# and add `xcrun notarytool submit ...` step.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONFIG="${LUMINA_BUILD_CONFIG:-release}"
SIGN_IDENTITY="${LUMINA_SIGN_IDENTITY:--}"
APP_DIR=".build/Lumina.app"
ENTITLEMENTS="Apps/LuminaDesktop/LuminaDesktop/LuminaDesktop.entitlements"
VERSION="0.7.0"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "→ Building LuminaDesktopApp (config=$CONFIG)"
swift build -c "$CONFIG" --product LuminaDesktopApp

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/LuminaDesktopApp"
[ -x "$BIN_PATH" ] || { echo "error: built binary not found at $BIN_PATH"; exit 1; }

echo "→ Packaging .app bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/Lumina"

# Embed app icon. Generate it on the fly if missing.
ICON_SRC="scripts/AppIcon.icns"
if [ ! -f "$ICON_SRC" ]; then
    echo "→ Icon not found; running scripts/generate-icon.swift"
    swift scripts/generate-icon.swift > /dev/null
fi
cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Lumina</string>
    <key>CFBundleIdentifier</key><string>app.lumina.LuminaDesktop</string>
    <key>CFBundleName</key><string>Lumina</string>
    <key>CFBundleDisplayName</key><string>Lumina</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Lumina VM Bundle</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key>
            <array><string>app.lumina.luminavm</string></array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>app.lumina.luminavm</string>
            <key>UTTypeDescription</key><string>Lumina VM Bundle</string>
            <key>UTTypeConformsTo</key><array><string>com.apple.package</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>luminaVM</string></array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF

echo "→ Signing with identity '$SIGN_IDENTITY'"
codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    "$APP_DIR" >/dev/null

# Verify signing
if codesign --verify --strict "$APP_DIR" 2>/dev/null; then
    echo "→ Codesign verified"
else
    echo "warn: codesign verify failed (ad-hoc sign is OK; Gatekeeper will warn on first open)"
fi

echo "→ Built: $APP_DIR"
echo "  size: $(du -sh "$APP_DIR" | cut -f1)"

if [ "${1:-}" = "--install" ]; then
    echo "→ Installing to /Applications/Lumina.app"
    pkill -lf "/Applications/Lumina.app" 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Lumina.app
    cp -R "$APP_DIR" /Applications/Lumina.app
    echo "→ Launching"
    open /Applications/Lumina.app
fi
