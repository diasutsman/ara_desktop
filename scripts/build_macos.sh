#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# ARA Assessment macOS Build Script
# Supports:
# - Apple Silicon (arm64)
# - Intel (x86_64), when dependencies support it
# - Developer ID signing when available
# - Apple Development signing as fallback
# - Ad-hoc signing when no certificate is available
# - Optional Apple notarization
# ============================================================

APP_NAME="ARA Assessment"
APP_FILE_NAME="ARA Assessment.app"

# 0 = warn about missing CPU architectures and continue
# 1 = fail if a binary lacks arm64 or x86_64
REQUIRE_UNIVERSAL="${REQUIRE_UNIVERSAL:-0}"

# Both values may remain empty.
MACOS_SIGNING_IDENTITY="${MACOS_SIGNING_IDENTITY:-}"
MACOS_NOTARY_PROFILE="${MACOS_NOTARY_PROFILE:-}"

say() {
  printf '\n==> %s\n' "$*"
}

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

# ------------------------------------------------------------
# 1. Find the Flutter project root
# ------------------------------------------------------------

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

# ------------------------------------------------------------
# 2. Check macOS build tools
# ------------------------------------------------------------

[[ "$(uname -s)" == "Darwin" ]] ||
  fail "This script must run on macOS."

command -v xcodebuild >/dev/null 2>&1 ||
  fail "Xcode is missing."

command -v codesign >/dev/null 2>&1 ||
  fail "codesign is missing."

command -v lipo >/dev/null 2>&1 ||
  fail "lipo is missing."

command -v hdiutil >/dev/null 2>&1 ||
  fail "hdiutil is missing."

command -v xcrun >/dev/null 2>&1 ||
  fail "xcrun is missing."

[[ -d "$PROJECT_ROOT/macos" ]] ||
  fail "macos/ directory is missing. Run: flutter create --platforms=macos ."

# ------------------------------------------------------------
# 3. Locate Flutter or FVM
# ------------------------------------------------------------

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
  fail "Flutter was not found. Install Flutter or FVM."
fi

# ------------------------------------------------------------
# 4. Read app version
# ------------------------------------------------------------

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

# ------------------------------------------------------------
# 5. Temporary files and automatic cleanup
# ------------------------------------------------------------

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ara-macos-build.XXXXXX")"

PROJECT_PBXPROJ="$PROJECT_ROOT/macos/Runner.xcodeproj/project.pbxproj"
PROJECT_BACKUP="$TEMP_ROOT/project.pbxproj.original"
PATCHED_PBXPROJ=0

cleanup() {
  if [[ "${PATCHED_PBXPROJ:-0}" == "1" &&
        -f "${PROJECT_BACKUP:-}" ]]; then

    cp "$PROJECT_BACKUP" "$PROJECT_PBXPROJ" ||
      printf '%s\n' \
        "WARNING: Could not restore the original Xcode project file." >&2
  fi

  if [[ -n "${TEMP_ROOT:-}" && -d "$TEMP_ROOT" ]]; then
    rm -rf "$TEMP_ROOT"
  fi
}

trap cleanup EXIT

# ------------------------------------------------------------
# 6. Detect available signing certificates
# ------------------------------------------------------------

say "Detecting available signing certificates"

IDENTITIES="$(
  security find-identity -v -p codesigning 2>/dev/null || true
)"

# Prefer Developer ID for public distribution.
if [[ -z "$MACOS_SIGNING_IDENTITY" ]]; then
  MACOS_SIGNING_IDENTITY="$(
    printf '%s\n' "$IDENTITIES" |
      sed -n \
        's/.*"\(Developer ID Application:.*\)".*/\1/p' |
      head -n 1 || true
  )"
fi

# Use Apple Development if no Developer ID certificate exists.
if [[ -z "$MACOS_SIGNING_IDENTITY" ]]; then
  MACOS_SIGNING_IDENTITY="$(
    printf '%s\n' "$IDENTITIES" |
      sed -n \
        's/.*"\(Apple Development:.*\)".*/\1/p' |
      head -n 1 || true
  )"
fi

# Leave identity empty if no certificate is found.
if [[ -n "$MACOS_SIGNING_IDENTITY" ]]; then
  printf 'Signing identity: %s\n' "$MACOS_SIGNING_IDENTITY"
else
  printf '%s\n' "No signing identity found."
  printf '%s\n' "The build will use ad-hoc signing."
fi

# Determine whether the identity is suitable for notarization.
IS_DEVELOPER_ID=0

if [[ "$MACOS_SIGNING_IDENTITY" == "Developer ID Application:"* ]]; then
  IS_DEVELOPER_ID=1
fi

# Notarization runs only with Developer ID and a configured profile.
DO_NOTARIZE=0

if [[ "$IS_DEVELOPER_ID" == "1" &&
      -n "$MACOS_NOTARY_PROFILE" ]]; then
  DO_NOTARIZE=1
fi

# ------------------------------------------------------------
# 7. Display build information
# ------------------------------------------------------------

printf '\n============================================================\n'
printf ' Application: %s\n' "$APP_NAME"
printf ' Version:     %s\n' "$VERSION"
printf ' Project:     %s\n' "$PROJECT_ROOT"
printf ' Flutter:     %s\n' "${FLUTTER[*]}"
printf ' Signing:     %s\n' "${MACOS_SIGNING_IDENTITY:-Ad-hoc}"
printf ' Notarize:    %s\n' "$DO_NOTARIZE"
printf ' Output:      %s\n' "$DMG_PATH"
printf '============================================================\n'

# ------------------------------------------------------------
# 8. Check Xcode and Flutter
# ------------------------------------------------------------

say "Checking Xcode"

xcodebuild -version

say "Checking Flutter"

"${FLUTTER[@]}" --version

# ------------------------------------------------------------
# 9. Fetch dependencies
# ------------------------------------------------------------

say "Running Flutter pub get"

"${FLUTTER[@]}" pub get

# ------------------------------------------------------------
# 10. Install CocoaPods dependencies
# ------------------------------------------------------------

if [[ -f "$PROJECT_ROOT/macos/Podfile" ]]; then
  if command -v pod >/dev/null 2>&1; then
    say "Installing CocoaPods dependencies"

    if ! (cd "$PROJECT_ROOT/macos" && pod install); then
      printf '%s\n' \
        "WARNING: pod install failed. Continuing to the Flutter build."
    fi
  else
    printf '%s\n' \
      "WARNING: CocoaPods is missing. The Flutter build may require it."
  fi
fi

# ------------------------------------------------------------
# 11. Prepare standard Xcode architectures
# ------------------------------------------------------------

if [[ -f "$PROJECT_PBXPROJ" ]]; then
  say "Preparing Xcode architecture settings"

  cp "$PROJECT_PBXPROJ" "$PROJECT_BACKUP"
  PATCHED_PBXPROJ=1

  /usr/bin/perl -0pi -e '
    s/^[ \t]*ARCHS = [^;]+;/        ARCHS = "\$(ARCHS_STANDARD)";/mg;
    s/^[ \t]*ONLY_ACTIVE_ARCH = YES;/        ONLY_ACTIVE_ARCH = NO;/mg;
  ' "$PROJECT_PBXPROJ"
fi

# ------------------------------------------------------------
# 12. Build Flutter macOS release
# ------------------------------------------------------------

say "Building Flutter release application"

"${FLUTTER[@]}" build macos --release

[[ -d "$BUILD_PRODUCTS" ]] ||
  fail "Release output was not found: $BUILD_PRODUCTS"

# ------------------------------------------------------------
# 13. Find generated .app
# ------------------------------------------------------------

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
      -maxdepth 1 \
      -type d \
      -name '*.app' \
      -print -quit
  )"
fi

[[ -n "$APP_BUNDLE" && -d "$APP_BUNDLE" ]] ||
  fail "No .app bundle was generated."

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"

[[ -f "$INFO_PLIST" ]] ||
  fail "The application is missing Info.plist."

APP_EXECUTABLE="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleExecutable' \
    "$INFO_PLIST" 2>/dev/null || true
)"

[[ -n "$APP_EXECUTABLE" ]] ||
  fail "Could not identify the app executable."

MAIN_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE"

[[ -f "$MAIN_BINARY" ]] ||
  fail "The main app executable is missing."

# ------------------------------------------------------------
# 14. Check Intel and Apple Silicon architectures
# ------------------------------------------------------------

say "Checking application architectures"

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
  fail "No Mach-O binaries were found inside the application."

if (( ARCH_FAILURE != 0 )); then
  if [[ "$REQUIRE_UNIVERSAL" == "1" ]]; then
    fail "Universal build check failed. One or more binaries lack arm64 or x86_64."
  else
    printf '%s\n' \
      "WARNING: Some binaries may not run on every MacBook."
  fi
else
  printf '%s\n' \
    "All checked Mach-O binaries support arm64 and x86_64."
fi

# ------------------------------------------------------------
# 15. Stage the application
# ------------------------------------------------------------

say "Staging application for DMG"

STAGING_DIR="$TEMP_ROOT/staging"
STAGED_APP="$STAGING_DIR/$APP_FILE_NAME"

mkdir -p "$STAGING_DIR"

/usr/bin/ditto "$APP_BUNDLE" "$STAGED_APP"

ln -s /Applications "$STAGING_DIR/Applications"

# ------------------------------------------------------------
# 16. Find release entitlements
# ------------------------------------------------------------

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

# ------------------------------------------------------------
# 17. Sign app
# ------------------------------------------------------------

say "Signing application"

if [[ -n "$MACOS_SIGNING_IDENTITY" ]]; then

  # Confirm that the identity still exists in the Keychain.
  if ! printf '%s\n' "$IDENTITIES" |
    grep -Fq "\"$MACOS_SIGNING_IDENTITY\""; then

    fail "The selected signing identity is not available in your Keychain."
  fi

  SIGN_ARGS=(
    --force
    --deep
    --sign "$MACOS_SIGNING_IDENTITY"
  )

  if [[ "$IS_DEVELOPER_ID" == "1" ]]; then
    SIGN_ARGS+=(--options runtime --timestamp)
  fi

  if [[ -n "$ENTITLEMENTS" ]]; then
    SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
  fi

  codesign "${SIGN_ARGS[@]}" "$STAGED_APP"

else

  # No certificate is required for a local test build.
  # Ad-hoc signing does not make the app trusted by Gatekeeper.
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
fi

say "Verifying application signature"

codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

# ------------------------------------------------------------
# 18. Notarize the app, if supported
# ------------------------------------------------------------

NOTARIZED=0

if [[ "$DO_NOTARIZE" == "1" ]]; then
  say "Preparing app for Apple notarization"

  NOTARY_ZIP="$TEMP_ROOT/ARA_Assessment_notarization.zip"

  /usr/bin/ditto \
    -c -k \
    --sequesterRsrc \
    --keepParent \
    "$STAGED_APP" \
    "$NOTARY_ZIP"

  say "Submitting app to Apple"

  xcrun notarytool submit "$NOTARY_ZIP" \
    --keychain-profile "$MACOS_NOTARY_PROFILE" \
    --wait

  xcrun stapler staple "$STAGED_APP"
  xcrun stapler validate "$STAGED_APP"

  NOTARIZED=1

else
  printf '%s\n' \
    "Skipping notarization. A Developer ID certificate and notary profile are required."
fi

# ------------------------------------------------------------
# 19. Create DMG
# ------------------------------------------------------------

say "Creating DMG installer"

rm -f "$DMG_PATH"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

[[ -f "$DMG_PATH" ]] ||
  fail "DMG creation failed."

# ------------------------------------------------------------
# 20. Notarize the final DMG
# ------------------------------------------------------------

if [[ "$NOTARIZED" == "1" ]]; then

  say "Submitting DMG to Apple"

  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$MACOS_NOTARY_PROFILE" \
    --wait

  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"

  say "Checking Gatekeeper"

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

# ------------------------------------------------------------
# 21. Final result
# ------------------------------------------------------------

printf '\n============================================================\n'
printf ' BUILD COMPLETE\n'
printf ' Application: %s\n' "$APP_NAME"
printf ' DMG: %s\n' "$DMG_PATH"
printf '============================================================\n'

if [[ "$NOTARIZED" == "1" ]]; then
  printf '%s\n' "Status: Signed and notarized."
elif [[ "$IS_DEVELOPER_ID" == "1" ]]; then
  printf '%s\n' "Status: Developer ID signed, but not notarized."
elif [[ -n "$MACOS_SIGNING_IDENTITY" ]]; then
  printf '%s\n' "Status: Apple Development signed. Suitable for development testing."
else
  printf '%s\n' "Status: Ad-hoc signed. Suitable for local testing."
fi

printf '\nOutput directory:\n%s\n\n' "$OUTPUT_DIR"