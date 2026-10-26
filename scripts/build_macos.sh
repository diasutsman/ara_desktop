
#!/usr/bin/env bash
set -Eeuo pipefail

# ARA Assessment macOS builder.
# Builds a release app and packages it as a DMG.
# Developer ID signing and notarization are OPTIONAL.
# Without them, the DMG is suitable for local testing only.

APP_NAME="ARA Assessment"
APP_FILE_NAME="ARA Assessment.app"

# Do not fail packaging just because a native library is single-architecture.
# Set REQUIRE_UNIVERSAL=1 to enforce Intel + Apple Silicon compatibility.
REQUIRE_UNIVERSAL="${REQUIRE_UNIVERSAL:-0}"

# Signing credentials may be empty.
MACOS_SIGNING_IDENTITY="${MACOS_SIGNING_IDENTITY:-}"
MACOS_NOTARY_PROFILE="${MACOS_NOTARY_PROFILE:-}"

say() {
  printf '\n==> %s\n' "$*"
}

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

# Locate project root.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/pubspec.yaml" ]]; then
  PROJECT_ROOT="$SCRIPT_DIR"
elif [[ -f "$SCRIPT_DIR/../pubspec.yaml" ]]; then
  PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
else
  SEARCH_DIR="$SCRIPT_DIR"
  PROJECT_ROOT=""

  while [[ "$SEARCH_DIR" != "/" ]]; do
    if [[ -f "$SEARCH_DIR/pubspec.yaml" ]]; then
      PROJECT_ROOT="$SEARCH_DIR"
      break
    fi
    SEARCH_DIR="$(dirname -- "$SEARCH_DIR")"
  done

  [[ -n "$PROJECT_ROOT" ]] ||
    fail "Cannot find pubspec.yaml. Put this script in the project root or scripts/."
fi

cd "$PROJECT_ROOT"

# Check platform.
[[ "$(uname -s)" == "Darwin" ]] ||
  fail "Run this script on macOS, not Windows."

command -v xcodebuild >/dev/null 2>&1 ||
  fail "Xcode is missing. Install Xcode and select it using xcode-select."

command -v codesign >/dev/null 2>&1 ||
  fail "codesign is unavailable. Install Xcode Command Line Tools."

command -v lipo >/dev/null 2>&1 ||
  fail "lipo is unavailable."

command -v hdiutil >/dev/null 2>&1 ||
  fail "hdiutil is unavailable."

command -v xcrun >/dev/null 2>&1 ||
  fail "xcrun is unavailable."

[[ -d "$PROJECT_ROOT/macos" ]] ||
  fail "macos/ is missing. Run: flutter create --platforms=macos ."

# Find Flutter, preferring the project's FVM version.
FLUTTER=()

if command -v fvm >/dev/null 2>&1 &&
  { [[ -f "$PROJECT_ROOT/.fvmrc" ]] ||
    [[ -f "$PROJECT_ROOT/.fvm/fvm_config.json" ]]; }; then
  FLUTTER=(fvm flutter)
elif [[ -x "$PROJECT_ROOT/.fvm/flutter_sdk/bin/flutter" ]]; then
  FLUTTER=("$PROJECT_ROOT/.fvm/flutter_sdk/bin/flutter")
elif [[ -x "$HOME/fvm/default/bin/flutter" ]]; then
  FLUTTER=("$HOME/fvm/default/bin/flutter")
elif [[ -x "$HOME/.fvm/default/bin/flutter" ]]; then
  FLUTTER=("$HOME/.fvm/default/bin/flutter")
elif command -v flutter >/dev/null 2>&1; then
  FLUTTER=("$(command -v flutter)")
else
  fail "Flutter was not found. Install Flutter or FVM and configure PATH."
fi

# Read version from pubspec.yaml.
VERSION="$(
  awk '$1 == "version:" {
    gsub(/\r/, "")
    print $2
    exit
  }' "$PROJECT_ROOT/pubspec.yaml"
)"

VERSION="${VERSION#\"}"
VERSION="${VERSION%\"}"
VERSION="${VERSION#\'}"
VERSION="${VERSION%\'}"

[[ -n "$VERSION" ]] || VERSION="1.0.0+1"

VERSION_SAFE="$(
  printf '%s' "$VERSION" |
    tr -c 'A-Za-z0-9._+-' '_'
)"

OUTPUT_DIR="$PROJECT_ROOT/build/macos"
BUILD_PRODUCTS="$OUTPUT_DIR/Build/Products/Release"
DMG_PATH="$OUTPUT_DIR/ARA_Assessment_${VERSION_SAFE}.dmg"

mkdir -p "$OUTPUT_DIR"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ara-macos-build.XXXXXX")"

PROJECT_PBXPROJ="$PROJECT_ROOT/macos/Runner.xcodeproj/project.pbxproj"
PROJECT_BACKUP="$TEMP_ROOT/project.pbxproj.original"
PATCHED_PBXPROJ=0

cleanup() {
  if [[ "$PATCHED_PBXPROJ" == "1" &&
        -f "$PROJECT_BACKUP" ]]; then
    cp "$PROJECT_BACKUP" "$PROJECT_PBXPROJ" ||
      printf '%s\n' "WARNING: Could not restore the Xcode project file." >&2
  fi

  if [[ -n "${TEMP_ROOT:-}" && -d "$TEMP_ROOT" ]]; then
    rm -rf "$TEMP_ROOT"
  fi
}

trap cleanup EXIT

# Automatically detect a Developer ID certificate if available.
# If none exists, leave the identity EMPTY. This is not a build error.
if [[ -z "$MACOS_SIGNING_IDENTITY" ]]; then
  MACOS_SIGNING_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null |
      sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p' |
      head -n 1 || true
  )"
fi

printf '%s\n' '============================================================'
printf ' App:      %s\n' "$APP_NAME"
printf ' Version:  %s\n' "$VERSION"
printf ' Project:  %s\n' "$PROJECT_ROOT"
printf ' Flutter:  %s\n' "${FLUTTER[*]}"
printf ' Signing:  %s\n' "${MACOS_SIGNING_IDENTITY:-Ad-hoc (no Developer ID)}"
printf ' Output:   %s\n' "$DMG_PATH"
printf '%s\n' '============================================================'

say "Checking Xcode and Flutter"

"${FLUTTER[@]}" --version
xcodebuild -version

say "Downloading Flutter dependencies"

"${FLUTTER[@]}" pub get

# Install native plugin dependencies when CocoaPods is available.
if [[ -f "$PROJECT_ROOT/macos/Podfile" ]]; then
  if command -v pod >/dev/null 2>&1; then
    say "Installing CocoaPods dependencies"
    (cd "$PROJECT_ROOT/macos" && pod install)
  else
    printf '%s\n' "WARNING: CocoaPods is unavailable. Native plugin builds may fail."
  fi
fi

# Configure standard architectures during this build.
# The original project file is restored automatically at exit.
if [[ -f "$PROJECT_PBXPROJ" ]]; then
  say "Preparing Xcode architecture settings"

  cp "$PROJECT_PBXPROJ" "$PROJECT_BACKUP"
  PATCHED_PBXPROJ=1

  /usr/bin/perl -0pi -e '
    s/^[ \t]*ARCHS = [^;]+;/        ARCHS = "$(ARCHS_STANDARD)";/mg;
    s/^[ \t]*ONLY_ACTIVE_ARCH = YES;/        ONLY_ACTIVE_ARCH = NO;/mg;
  ' "$PROJECT_PBXPROJ"
fi

say "Building macOS release app"

"${FLUTTER[@]}" build macos --release

[[ -d "$BUILD_PRODUCTS" ]] ||
  fail "Flutter release output was not found: $BUILD_PRODUCTS"

# Find the generated application.
APP_BUNDLE=""

for CANDIDATE in \
  "$BUILD_PRODUCTS/ara_desktop.app" \
  "$BUILD_PRODUCTS/Runner.app"; do
  if [[ -d "$CANDIDATE" ]]; then
    APP_BUNDLE="$CANDIDATE"
    break
  fi
done

if [[ -z "$APP_BUNDLE" ]]; then
  APP_BUNDLE="$(
    find "$BUILD_PRODUCTS" \
      -maxdepth 1 -type d -name '*.app' -print -quit
  )"
fi

[[ -n "$APP_BUNDLE" && -d "$APP_BUNDLE" ]] ||
  fail "No .app bundle was generated."

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"

[[ -f "$INFO_PLIST" ]] ||
  fail "The app is missing Contents/Info.plist."

APP_EXECUTABLE="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleExecutable' \
    "$INFO_PLIST" 2>/dev/null || true
)"

[[ -n "$APP_EXECUTABLE" ]] ||
  fail "Could not determine the main app executable."

MAIN_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE"

[[ -f "$MAIN_BINARY" ]] ||
  fail "The main executable is missing: $MAIN_BINARY"

# Check whether every bundled native binary supports both architectures.
say "Checking Intel and Apple Silicon architectures"

ARCH_FAILURE=0
MACHO_COUNT=0

while IFS= read -r -d '' FILE_PATH; do
  DESCRIPTION="$(file -b "$FILE_PATH" 2>/dev/null || true)"

  [[ "$DESCRIPTION" == *Mach-O* ]] || continue

  MACHO_COUNT=$((MACHO_COUNT + 1))
  ARCHS="$(lipo -archs "$FILE_PATH" 2>/dev/null || true)"
  MISSING=""

  for REQUIRED_ARCH in arm64 x86_64; do
    case " $ARCHS " in
      *" $REQUIRED_ARCH "*) ;;
      *) MISSING="$MISSING $REQUIRED_ARCH" ;;
    esac
  done

  if [[ -n "$MISSING" ]]; then
    printf 'WARNING: %s\n' "$FILE_PATH" >&2
    printf '  Found: %s\n' "${ARCHS:-unknown}" >&2
    printf '  Missing:%s\n' "$MISSING" >&2
    ARCH_FAILURE=1
  fi
done < <(find "$APP_BUNDLE/Contents" -type f -print0)

(( MACHO_COUNT > 0 )) ||
  fail "No Mach-O binaries were found in the app."

if (( ARCH_FAILURE != 0 )); then
  if [[ "$REQUIRE_UNIVERSAL" == "1" ]]; then
    fail "Some bundled binaries lack Intel or Apple Silicon support. Check the affected native plugins."
  else
    printf '%s\n' "WARNING: Some native binaries are not universal. This app may not run on every MacBook."
  fi
else
  printf '%s\n' "Verified: all bundled Mach-O binaries support arm64 and x86_64."
fi

# Prepare the installer directory.
STAGING_DIR="$TEMP_ROOT/staging"
STAGED_APP="$STAGING_DIR/$APP_FILE_NAME"

mkdir -p "$STAGING_DIR"

say "Preparing the application bundle"

/usr/bin/ditto "$APP_BUNDLE" "$STAGED_APP"

ln -s /Applications "$STAGING_DIR/Applications"

# Locate release entitlements if present.
ENTITLEMENTS=""

for CANDIDATE in \
  "$PROJECT_ROOT/macos/Runner/Release.entitlements" \
  "$PROJECT_ROOT/macos/Runner/Runner.entitlements" \
  "$PROJECT_ROOT/macos/Runner/Runner-Release.entitlements"; do
  if [[ -f "$CANDIDATE" ]]; then
    ENTITLEMENTS="$CANDIDATE"
    break
  fi
done

# Sign the app.
if [[ -n "$MACOS_SIGNING_IDENTITY" ]]; then
  say "Signing with Developer ID"

  if ! security find-identity -v -p codesigning 2>/dev/null |
    grep -Fq "$MACOS_SIGNING_IDENTITY"; then

    fail "The configured signing identity does not exist in the Keychain. Clear MACOS_SIGNING_IDENTITY to use ad-hoc signing."
  fi

  codesign \
    --force \
    --deep \
    --sign "$MACOS_SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    "$STAGED_APP"

  if [[ -n "$ENTITLEMENTS" ]]; then
    codesign \
      --force \
      --sign "$MACOS_SIGNING_IDENTITY" \
      --options runtime \
      --timestamp \
      --entitlements "$ENTITLEMENTS" \
      "$STAGED_APP"
  else
    codesign \
      --force \
      --sign "$MACOS_SIGNING_IDENTITY" \
      --options runtime \
      --timestamp \
      "$STAGED_APP"
  fi

else
  # No certificate is required to build and package a local test app.
  say "No Developer ID certificate found. Using ad-hoc signing."

  if [[ -n "$ENTITLEMENTS" ]]; then
    codesign \
      --force \
      --deep \
      --sign - \
      --entitlements "$ENTITLEMENTS" \
      "$STAGED_APP"
  else
    codesign \
      --force \
      --deep \
      --sign - \
      "$STAGED_APP"
  fi

  printf '%s\n' "NOTE: Ad-hoc signing does not establish trust with Gatekeeper."
fi

say "Verifying app signature"

codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

# Notarization is automatic only when BOTH credentials are available.
# Empty signing identity or empty notary profile never blocks packaging.
NOTARIZED=0

if [[ -n "$MACOS_SIGNING_IDENTITY" &&
      -n "$MACOS_NOTARY_PROFILE" ]]; then

  say "Submitting the app to Apple for notarization"

  NOTARY_ZIP="$TEMP_ROOT/ARA_Assessment_for_notarization.zip"

  /usr/bin/ditto \
    -c -k \
    --sequesterRsrc \
    --keepParent \
    "$STAGED_APP" \
    "$NOTARY_ZIP"

  xcrun notarytool submit "$NOTARY_ZIP" \
    --keychain-profile "$MACOS_NOTARY_PROFILE" \
    --wait

  xcrun stapler staple "$STAGED_APP"
  xcrun stapler validate "$STAGED_APP"

  NOTARIZED=1

elif [[ -n "$MACOS_SIGNING_IDENTITY" ]]; then
  printf '%s\n' "NOTICE: Developer ID signing is enabled, but no notary profile is configured."
  printf '%s\n' "Skipping notarization and continuing the build."
else
  printf '%s\n' "NOTICE: No Developer ID certificate. Skipping notarization."
fi

# Create the DMG.
say "Creating the DMG installer"

rm -f "$DMG_PATH"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

[[ -f "$DMG_PATH" ]] ||
  fail "The DMG was not created."

# Notarize the finished installer if credentials are configured.
if [[ "$NOTARIZED" == "1" ]]; then
  say "Submitting the DMG to Apple for notarization"

  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$MACOS_NOTARY_PROFILE" \
    --wait

  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"

  say "Checking Gatekeeper acceptance"

  spctl --assess \
    --type execute \
    --verbose=2 \
    "$STAGED_APP"

  spctl --assess \
    --type open \
    --context context:primary-signature \
    --verbose=2 \
    "$DMG_PATH"
fi

printf '\n============================================================\n'
printf ' SUCCESS: DMG created\n'
printf ' Application: %s\n' "$APP_NAME"
printf ' Output:      %s\n' "$DMG_PATH"
printf '============================================================\n'

if [[ "$NOTARIZED" == "1" ]]; then
  printf '%s\n' "Status: Developer ID signed and notarized."
else
  printf '%s\n' "Status: Build complete, but public distribution is not verified."
  printf '%s\n' "Without Developer ID signing and notarization, other Macs may block the app."
fi

printf '\n'
