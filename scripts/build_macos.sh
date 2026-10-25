#!/bin/bash
set -e

# Ensure Homebrew and standard macOS developer paths are included
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.pub-cache/bin:$PATH"

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

# Extract version from pubspec.yaml (stripping carriage return \r if present)
VERSION=$(grep '^version:' "$PROJECT_ROOT/pubspec.yaml" | head -n 1 | awk '{print $2}' | tr -d '\r')
if [ -z "$VERSION" ]; then
  VERSION="1.0.0+1"
fi

APP_NAME="ARA Assessment"
DMG_NAME="ARA_Assessment_${VERSION}"
BUILD_DIR="$PROJECT_ROOT/build/macos/Build/Products/Release"
OUTPUT_DIR="$PROJECT_ROOT/build/macos"

echo "=========================================================="
echo " Building $APP_NAME macOS Release & DMG Installer"
echo " Version: $VERSION"
echo "=========================================================="

# 1. Detect flutter command (FVM or system flutter)
FLUTTER_CMD="flutter"
if command -v fvm >/dev/null 2>&1; then
  FLUTTER_CMD="fvm flutter"
elif [ -f "$HOME/.fvm/default/bin/flutter" ]; then
  FLUTTER_CMD="$HOME/.fvm/default/bin/flutter"
elif [ -f "/opt/homebrew/bin/flutter" ]; then
  FLUTTER_CMD="/opt/homebrew/bin/flutter"
fi

echo "==> Using Flutter command: $FLUTTER_CMD"

# 2. Fetch Flutter dependencies
echo "==> Running Flutter pub get..."
$FLUTTER_CMD pub get

# 3. CocoaPods installation if needed
if command -v pod >/dev/null 2>&1 && [ -d "$PROJECT_ROOT/macos" ]; then
  echo "==> Updating CocoaPods dependencies..."
  (cd "$PROJECT_ROOT/macos" && pod install) || {
    echo "Notice: manual pod install exited with warning, proceeding with flutter build..."
  }
fi

# 4. Build macOS release bundle
echo "==> Building Flutter macOS release bundle..."
$FLUTTER_CMD build macos --release

# 5. Detect generated .app bundle
APP_BUNDLE="$BUILD_DIR/ara_desktop.app"
if [ ! -d "$APP_BUNDLE" ]; then
  DETECTED_APP=$(find "$BUILD_DIR" -maxdepth 1 -name "*.app" | head -n 1)
  if [ -n "$DETECTED_APP" ] && [ -d "$DETECTED_APP" ]; then
    APP_BUNDLE="$DETECTED_APP"
  else
    echo "ERROR: Release app bundle not found in $BUILD_DIR"
    exit 1
  fi
fi

echo "==> Found App bundle at: $APP_BUNDLE"

mkdir -p "$OUTPUT_DIR"
FINAL_DMG="$OUTPUT_DIR/${DMG_NAME}.dmg"
rm -f "$FINAL_DMG"

echo "==> Staging macOS DMG Installer..."

# Create a clean temporary staging directory with properly named .app and /Applications symlink
STAGING_DIR=$(mktemp -d /tmp/ara_dmg_staging.XXXXXX)
cp -R "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Enforcing executable permissions and code signature..."
chmod -R 755 "$STAGING_DIR/$APP_NAME.app"
chmod +x "$STAGING_DIR/$APP_NAME.app/Contents/MacOS/"*

# Remove any existing quarantine attributes from staging files
xattr -cr "$STAGING_DIR/$APP_NAME.app" 2>/dev/null || true

# Re-sign the app ad-hoc while preserving Release.entitlements
ENTITLEMENTS="$PROJECT_ROOT/macos/Runner/Release.entitlements"
if [ -f "$ENTITLEMENTS" ]; then
  echo "==> Signing app bundle with Release.entitlements..."
  codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$STAGING_DIR/$APP_NAME.app" 2>/dev/null || {
    echo "Notice: codesign with entitlements returned warning, falling back to basic ad-hoc sign..."
    codesign --force --deep --sign - "$STAGING_DIR/$APP_NAME.app"
  }
else
  codesign --force --deep --sign - "$STAGING_DIR/$APP_NAME.app"
fi

# 6. Package into DMG Installer
echo "==> Packaging into DMG file: $FINAL_DMG"

# Attempt create-dmg for styled DMG window if available
if command -v create-dmg >/dev/null 2>&1; then
  echo "==> Attempting create-dmg for styled installer..."
  rm -f "$FINAL_DMG"
  if create-dmg \
    --volname "$APP_NAME" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "$APP_NAME.app" 160 200 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 440 200 \
    --no-internet-enable \
    "$FINAL_DMG" \
    "$STAGING_DIR"; then
      echo "==> Styled DMG created successfully with create-dmg."
  else
      echo "Notice: create-dmg failed or timed out. Falling back to native hdiutil..."
      rm -f "$FINAL_DMG"
  fi
fi

# 100% reliable fallback: use native macOS hdiutil
if [ ! -f "$FINAL_DMG" ]; then
  echo "==> Packaging DMG using native macOS 'hdiutil'..."
  rm -f "$FINAL_DMG"
  hdiutil create -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov -format UDZO \
    "$FINAL_DMG"
fi

# Clean up staging directory
rm -rf "$STAGING_DIR"

if [ -f "$FINAL_DMG" ]; then
  echo ""
  echo "=========================================================="
  echo " [SUCCESS] macOS DMG Installer created successfully!"
  echo " Output: $FINAL_DMG"
  echo "=========================================================="
  echo ""
  echo "NOTE for macOS Gatekeeper (if downloaded from Internet):"
  echo "1. Drag '$APP_NAME' to /Applications"
  echo "2. If macOS says 'is damaged and can\'t be opened' or blocks it:"
  echo "   Run in Terminal: xattr -cr '/Applications/$APP_NAME.app'"
  echo "   OR: Right-click '$APP_NAME.app' -> Open -> Open"
  echo "=========================================================="
else
  echo "ERROR: DMG was not found at $FINAL_DMG"
  exit 1
fi
