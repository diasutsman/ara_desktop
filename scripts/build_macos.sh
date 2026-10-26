#!/usr/bin/env bash
set -Eeuo pipefail

# ARA Assessment macOS release builder.
# Distribution builds require Developer ID signing and Apple notarization.
# For local testing only, set REQUIRE_NOTARIZATION=0.

APP_NAME="ARA Assessment"
APP_FILE_NAME="ARA Assessment.app"
REQUIRE_UNIVERSAL="${REQUIRE_UNIVERSAL:-1}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-1}"
MACOS_SIGNING_IDENTITY="${MACOS_SIGNING_IDENTITY:-}"
MACOS_NOTARY_PROFILE="${MACOS_NOTARY_PROFILE:-}"

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

say() {
  printf '\n==> %s\n' "$*"
}

# Locate the Flutter project root.
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

# macOS and Xcode checks.
[[ "$(uname -s)" == "Darwin" ]] ||
  fail "Run this script on a Mac, not Windows."

command -v xcodebuild >/dev/null 2>&1 ||
  fail "Xcode is missing. Install Xcode and open it once."

command -v codesign >/dev/null 2>&1 ||
  fail "codesign is unavailable. Install Xcode Command Line Tools."

command -v lipo >/dev/null 2>&1 ||
  fail "lipo is unavailable. Install Xcode Command Line Tools."

command -v hdiutil >/dev/null 2>&1 ||
  fail "hdiutil is unavailable."

command -v xcrun >/dev/null 2>&1 ||
  fail "xcrun is unavailable."

[[ -d "$PROJECT_ROOT/macos" ]] ||
  fail "The macos/ directory is missing. Run: flutter create --platforms=macos ."

# Detect Flutter, preferring the project's FVM version.
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

# Read app version from pubspec.yaml.
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
PROJECT_PBXPROJ_BACKUP="$TEMP_ROOT/Runner-project.pbxproj.original"
PATCHED_PBXPROJ=0

cleanup() {
  # Restore the original Xcode project file.
  if [[ "$PATCHED_PBXPROJ" == "1" &&
        -f "$PROJECT_PBXPROJ_BACKUP" ]]; then
    cp "$PROJECT_PBXPROJ_BACKUP" "$PROJECT_PBXPROJ" ||
      printf '%s\n' "WARNING: Failed to restore the original Xcode project file." >&2
  fi

  if [[ -n "${TEMP_ROOT:-}" && -d "$TEMP_ROOT" ]]; then
    rm -rf "$TEMP_ROOT"
  fi
}

trap cleanup EXIT

# Detect an installed Developer ID Application certificate.
if [[ -z "$MACOS_SIGNING_IDENTITY" ]]; then
  MACOS_SIGNING_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null |
      sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p' |
      head -n 1 || true
  )"
fi

# Refuse to create a misleading distribution build.
if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
  [[ -n "$MACOS_SIGNING_IDENTITY" ]] ||
    fail "No Developer ID Application certificate found. Configure MACOS_SIGNING_IDENTITY."

  [[ -n "$MACOS_NOTARY_PROFILE" ]] ||
    fail "MACOS_NOTARY_PROFILE is missing. Configure your Apple notarization credentials."
fi

printf '%s\n' '============================================================'
printf ' Building: %s\n' "$APP_NAME"
printf ' Version:  %s\n' "$VERSION"
printf ' Project:  %s\n' "$PROJECT_ROOT"
printf ' Flutter:  %s\n' "${FLUTTER[*]}"
printf ' Output:   %s\n' "$DMG_PATH"
printf '%s\n' '============================================================'

say "Checking Flutter and Xcode"

"${FLUTTER[@]}" --version
xcodebuild -version

say "Fetching Flutter dependencies"

"${FLUTTER[@]}" pub get

# Install native dependencies used by Flutter plugins.
if [[ -f "$PROJECT_ROOT/macos/Podfile" ]]; then
  if command -v pod >/dev/null 2>&1; then
    say "Installing CocoaPods dependencies"
    (cd "$PROJECT_ROOT/macos" && pod install)
  else
    fail "CocoaPods is required by this project but was not found. Install CocoaPods first."
  fi
fi

# Temporarily configure standard universal architectures.
# The original Xcode project is restored at script exit.
if [[ -f "$PROJECT_PBXPROJ" ]]; then
  say "Preparing universal architecture settings"

  cp "$PROJECT_PBXPROJ" "$PROJECT_PBXPROJ_BACKUP"
  PATCHED_PBXPROJ=1

  /usr/bin/perl -0pi -e \
    's/^[ \t]*ARCHS = [^;]+;/        ARCHS = "$(ARCHS_STANDARD)";/mg;
     s/^[ \t]*ONLY_ACTIVE_ARCH = YES;/        ONLY_ACTIVE_ARCH = NO;/mg' \
    "$PROJECT_PBXPROJ"
fi

say "Building Flutter macOS release"

"${FLUTTER[@]}" build macos --release

[[ -d "$BUILD_PRODUCTS" ]] ||
  fail "Release output not found: $BUILD_PRODUCTS"

# Locate the generated app.
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
  fail "Could not locate the main app executable."

MAIN_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE"

[[ -f "$MAIN_BINARY" ]] ||
  fail "The app executable is missing: $MAIN_BINARY"

# Verify Intel and Apple Silicon support in every bundled Mach-O binary.
say "Checking Intel and Apple Silicon compatibility"

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
    printf 'ARCHITECTURE ERROR: %s\n' "$FILE_PATH" >&2
    printf '  Found: %s\n' "${ARCHS:-unknown}" >&2
    printf '  Missing:%s\n' "$MISSING" >&2
    ARCH_FAILURE=1
  fi
done < <(find "$APP_BUNDLE/Contents" -type f -print0)

(( MACHO_COUNT > 0 )) ||
  fail "No Mach-O executables were found inside the app."

if (( ARCH_FAILURE != 0 )); then
  if [[ "$REQUIRE_UNIVERSAL" == "1" ]]; then
    fail "The app is not universal. Check Runner Build Settings, native Flutter plugins, and both arm64 and x86_64 dependency support."
  else
    printf '%s\n' "WARNING: Some native binaries do not support both architectures."
  fi
else
  printf '%s\n' "Verified: all bundled Mach-O binaries support arm64 and x86_64."
fi

# Prepare the DMG contents.
STAGING_DIR="$TEMP_ROOT/staging"
STAGED_APP="$STAGING_DIR/$APP_FILE_NAME"

mkdir -p "$STAGING_DIR"

say "Staging application"

/usr/bin/ditto "$APP_BUNDLE" "$STAGED_APP"

ln -s /Applications "$STAGING_DIR/Applications"

# Find the release entitlements file, if the project provides one.
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

# Sign the application.
if [[ -n "$MACOS_SIGNING_IDENTITY" ]]; then
  say "Signing app with Developer ID"

  if ! security find-identity -v -p codesigning 2>/dev/null |
       grep -Fq "$MACOS_SIGNING_IDENTITY"; then
    fail "Signing identity is not available in your keychain: $MACOS_SIGNING_IDENTITY"
  fi

  # Sign nested code and enable the hardened runtime for notarization.
  codesign \
    --force \
    --deep \
    --sign "$MACOS_SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    "$STAGED_APP"

  # Apply the application's own entitlements to the outer bundle.
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
  if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
    fail "A Developer ID Application certificate is required."
  fi

  printf '%s\n' "WARNING: This is an ad-hoc signed local testing build."
  printf '%s\n' "Other Macs may block it. Do not distribute this build."

  codesign --force --deep --sign - "$STAGED_APP"

  if [[ -n "$ENTITLEMENTS" ]]; then
    codesign \
      --force \
      --sign - \
      --entitlements "$ENTITLEMENTS" \
      "$STAGED_APP"
  else
    codesign --force --sign - "$STAGED_APP"
  fi
fi

say "Verifying application signature"

codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

# Notarize the application when both credentials are configured.
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
fi

# Create the installer disk image.
say "Creating DMG installer"

rm -f "$DMG_PATH"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

# Notarize and validate the finished DMG.
if [[ "$NOTARIZED" == "1" ]]; then
  say "Submitting the DMG to Apple for notarization"

  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$MACOS_NOTARY_PROFILE" \
    --wait

  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"

  say "Running Gatekeeper assessments"

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
printf ' BUILD COMPLETE\n'
printf ' App: %s\n' "$APP_NAME"
printf ' DMG: %s\n' "$DMG_PATH"
printf '============================================================\n'

if [[ "$NOTARIZED" == "1" ]]; then
  printf '%s\n' "Status: signed, notarized, stapled, and assessed by Gatekeeper."
elif [[ -z "$MACOS_SIGNING_IDENTITY" ]]; then
  printf '%s\n' "Status: LOCAL TEST ONLY. Do not distribute this DMG."
else
  printf '%s\n' "Status: signed but not notarized. Public distribution is not ready."
fi