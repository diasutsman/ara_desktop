#!/bin/bash
set -e

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

# Extract version from pubspec.yaml
VERSION=$(grep '^version:' "$PROJECT_ROOT/pubspec.yaml" | head -n 1 | awk '{print $2}' | tr -d '\r')
if [ -z "$VERSION" ]; then
  VERSION="1.0.0+1"
fi

APP_NAME="ARA Assessment"
DMG_NAME="ARA_Assessment_${VERSION}"
BUILD_DIR="$PROJECT_ROOT/build/macos/Build/Products/Release"
OUTPUT_DIR="$PROJECT_ROOT/build/macos"
APP_BUNDLE="$BUILD_DIR/ara_desktop.app"

echo "=========================================================="
echo " Building $APP_NAME macOS Release & DMG Installer"
echo " Version: $VERSION"
echo "=========================================================="

# 1. Detect flutter command (fvm flutter or system flutter)
FLUTTER_CMD="flutter"
if command -v fvm >/dev/null 2>&1; then
  FLUTTER_CMD="fvm flutter"
fi

echo "==> Running Flutter dependencies & CocoaPods..."
$FLUTTER_CMD pub get

if [ -d "$PROJECT_ROOT/macos" ]; then
  echo "==> Running pod install in macos/..."
  (cd "$PROJECT_ROOT/macos" && pod install)
fi

echo "==> Building Flutter macOS release bundle..."
$FLUTTER_CMD build macos --release

if [ ! -d "$APP_BUNDLE" ]; then
  echo "ERROR: App bundle not found at $APP_BUNDLE"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
FINAL_DMG="$OUTPUT_DIR/${DMG_NAME}.dmg"
rm -f "$FINAL_DMG"

echo "==> Packaging into macOS DMG Installer..."

# Create a clean staging directory with properly named .app and /Applications symlink
STAGING_DIR=$(mktemp -d /tmp/ara_dmg_staging.XXXXXX)
cp -R "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Enforcing executable permissions and code signature..."
chmod -R 755 "$STAGING_DIR/$APP_NAME.app"
chmod +x "$STAGING_DIR/$APP_NAME.app/Contents/MacOS/"*

# Remove any quarantine attributes from staging files
xattr -cr "$STAGING_DIR/$APP_NAME.app"

# Re-sign the renamed .app ad-hoc so code signature integrity is preserved for Gatekeeper
codesign --force --deep --sign - "$STAGING_DIR/$APP_NAME.app"

# Try create-dmg for an automated styled installer window if available
if command -v create-dmg >/dev/null 2>&1; then
  echo "==> Attempting create-dmg for styled installer..."
  create-dmg \
    --volname "$APP_NAME" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "$APP_NAME.app" 160 200 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 440 200 \
    --no-internet-enable \
    "$FINAL_DMG" \
    "$STAGING_DIR" || {
      echo "Notice: create-dmg encountered an AppleScript/Finder timeout or remote display issue."
    }
fi

# 100% reliable fallback: if create-dmg wasn't installed or failed, use native macOS hdiutil
if [ ! -f "$FINAL_DMG" ]; then
  echo "==> Packaging DMG using native macOS 'hdiutil' (100% reliable)..."
  hdiutil create -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov -format UDZO \
    "$FINAL_DMG"
fi

rm -rf "$STAGING_DIR"

if [ -f "$FINAL_DMG" ]; then
  echo ""
  echo "=========================================================="
  echo " [SUCCESS] macOS DMG Installer created successfully!"
  echo " Output: $FINAL_DMG"
  echo "=========================================================="
else
  echo "Warning: Build finished, but DMG was not found at $FINAL_DMG"
fi
