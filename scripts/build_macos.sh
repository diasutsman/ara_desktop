
#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# ARA ASSESSMENT
# Production macOS Release DMG builder
#
# Build configuration: Release
# Architectures: arm64 + x86_64
# Signing: Developer ID Application
# Distribution: Apple notarization
#
# NO fallback to Apple Development or ad-hoc signing.
# ============================================================

APP_NAME="ARA Assessment"

MACOS_SIGNING_IDENTITY="${MACOS_SIGNING_IDENTITY:-}"
MACOS_NOTARY_PROFILE="${MACOS_NOTARY_PROFILE:-}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"

say() {
  printf '\n==> %s\n' "$*"
}

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

# ------------------------------------------------------------
# 1. Locate Flutter project
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
# 2. Validate macOS build tools
# ------------------------------------------------------------

[[ "$(uname -s)" == "Darwin" ]] ||
  fail "Run this script on macOS."

for TOOL in flutter xcodebuild xcrun codesign lipo hdiutil ditto plutil; do
  if ! command -v "$TOOL" >/dev/null 2>&1; then
    # Flutter may be supplied by FVM, so check it separately below.
    [[ "$TOOL" == "flutter" ]] && continue
    fail "Missing required tool: $TOOL. Check your Xcode installation."
  fi
done

[[ -d "$PROJECT_ROOT/macos/Runner.xcodeproj" ]] ||
  fail "macos/Runner.xcodeproj is missing."

# ------------------------------------------------------------
# 3. Detect Flutter / FVM
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
  fail "Flutter was not found. Install Flutter or configure FVM."
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

[[ -n "$VERSION" ]] ||
  fail "The version field is missing in pubspec.yaml."

VERSION_SAFE="$(
  printf '%s' "$VERSION" |
    tr -c 'A-Za-z0-9._+-' '_'
)"

OUTPUT_DIR="$PROJECT_ROOT/build/macos"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ara-release.XXXXXX")"

ARCHIVE_PATH="$TEMP_ROOT/ARA_Assessment.xcarchive"
DERIVED_DATA="$TEMP_ROOT/DerivedData"
EXPORT_DIR="$TEMP_ROOT/export"
EXPORT_OPTIONS="$TEMP_ROOT/ExportOptions.plist"
STAGING_DIR="$TEMP_ROOT/staging"

APP_ZIP="$TEMP_ROOT/ARA_Assessment_notarization.zip"
DMG_PATH="$OUTPUT_DIR/ARA_Assessment_${VERSION_SAFE}.dmg"

mkdir -p "$OUTPUT_DIR" "$EXPORT_DIR" "$STAGING_DIR"

cleanup() {
  if [[ -n "${TEMP_ROOT:-}" && -d "$TEMP_ROOT" ]]; then
    rm -rf "$TEMP_ROOT"
  fi
}

trap cleanup EXIT

# ------------------------------------------------------------
# 5. Require Developer ID Application
# ------------------------------------------------------------

say "Checking distribution certificate"

IDENTITIES="$(
  security find-identity -v -p codesigning 2>/dev/null || true
)"

# Automatically select Developer ID Application.
if [[ -z "$MACOS_SIGNING_IDENTITY" ]]; then
  MACOS_SIGNING_IDENTITY="$(
    printf '%s\n' "$IDENTITIES" |
      sed -n \
        's/.*"\(Developer ID Application:.*\)".*/\1/p' |
      head -n 1 || true
  )"
fi

if [[ -z "$MACOS_SIGNING_IDENTITY" ]]; then
  printf '\nAvailable signing identities:\n'
  printf '%s\n' "${IDENTITIES:-None}"

  fail "Developer ID Application is missing. Apple Development is not a substitute for a public distribution certificate."
fi

[[ "$MACOS_SIGNING_IDENTITY" == "Developer ID Application:"* ]] ||
  fail "MACOS_SIGNING_IDENTITY must start with Developer ID Application:"

IDENTITY_LINE="$(
  printf '%s\n' "$IDENTITIES" |
    grep -F "\"$MACOS_SIGNING_IDENTITY\"" |
    head -n 1 || true
)"

[[ -n "$IDENTITY_LINE" ]] ||
  fail "The selected Developer ID identity is not valid in the Keychain."

IDENTITY_HASH="$(
  printf '%s\n' "$IDENTITY_LINE" |
    sed -E \
      's/^[[:space:]]*[0-9]+\)[[:space:]]+([A-Fa-f0-9]{40}).*/\1/'
)"

[[ "$IDENTITY_HASH" =~ ^[A-Fa-f0-9]{40}$ ]] ||
  fail "Could not determine the signing certificate fingerprint."

# Determine the Apple Developer Team ID.
if [[ -z "$DEVELOPMENT_TEAM" ]]; then
  DEVELOPMENT_TEAM="$(
    printf '%s' "$MACOS_SIGNING_IDENTITY" |
      sed -E 's/^.*\(([A-Z0-9]{10})\)$/\1/'
  )"
fi

[[ "$DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]] ||
  fail "Could not determine the Apple Developer Team ID. Set DEVELOPMENT_TEAM manually."

# ------------------------------------------------------------
# 6. Require notarization credentials
# ------------------------------------------------------------

[[ -n "$MACOS_NOTARY_PROFILE" ]] ||
  fail "Set MACOS_NOTARY_PROFILE to your configured notarytool Keychain profile."

say "Validating notarization credentials"

xcrun notarytool history \
  --keychain-profile "$MACOS_NOTARY_PROFILE" \
  --output-format json >/dev/null

# ------------------------------------------------------------
# 7. Print build configuration
# ------------------------------------------------------------

printf '\n============================================================\n'
printf ' Application: %s\n' "$APP_NAME"
printf ' Version:     %s\n' "$VERSION"
printf ' Configuration: Release\n'
printf ' Architectures: arm64 + x86_64\n'
printf ' Signing:     %s\n' "$MACOS_SIGNING_IDENTITY"
printf ' Team ID:     %s\n' "$DEVELOPMENT_TEAM"
printf ' Notary profile: %s\n' "$MACOS_NOTARY_PROFILE"
printf ' Output:      %s\n' "$DMG_PATH"
printf '============================================================\n'

say "Checking Xcode"

xcodebuild -version

say "Checking Flutter"

"${FLUTTER[@]}" --version

# ------------------------------------------------------------
# 8. Resolve Flutter dependencies
# ------------------------------------------------------------

say "Getting Flutter dependencies"

"${FLUTTER[@]}" pub get

if [[ -f "$PROJECT_ROOT/macos/Podfile" ]]; then
  command -v pod >/dev/null 2>&1 ||
    fail "CocoaPods is required by this project but is not installed."

  say "Installing CocoaPods dependencies"

  (
    cd "$PROJECT_ROOT/macos"
    pod install
  )
fi

# ------------------------------------------------------------
# 9. Generate Flutter Release configuration
# ------------------------------------------------------------

say "Generating Flutter macOS Release configuration"

"${FLUTTER[@]}" build macos \
  --release \
  --config-only

# Use the workspace so CocoaPods integration is respected.
if [[ -d "$PROJECT_ROOT/macos/Runner.xcworkspace" ]]; then
  XCODE_PROJECT_ARGS=(
    -workspace
    "$PROJECT_ROOT/macos/Runner.xcworkspace"
  )
else
  XCODE_PROJECT_ARGS=(
    -project
    "$PROJECT_ROOT/macos/Runner.xcodeproj"
  )
fi

# ------------------------------------------------------------
# 10. Create a signed universal Release archive
# ------------------------------------------------------------

say "Building Xcode Release archive"

xcodebuild \
  "${XCODE_PROJECT_ARGS[@]}" \
  -scheme Runner \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$MACOS_SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  ENABLE_HARDENED_RUNTIME=YES \
  archive

[[ -d "$ARCHIVE_PATH/Products/Applications" ]] ||
  fail "Xcode archive does not contain an application."

# ------------------------------------------------------------
# 11. Export a Developer ID-signed application
# ------------------------------------------------------------

say "Preparing Xcode distribution export options"

cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>$IDENTITY_HASH</string>
  <key>teamID</key>
  <string>$DEVELOPMENT_TEAM</string>
  <key>stripSwiftSymbols</key>
  <true/>
</dict>
</plist>
PLIST

plutil -lint "$EXPORT_OPTIONS" >/dev/null

say "Exporting the distribution application"

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_DIR"

APP_BUNDLE="$(
  find "$EXPORT_DIR" \
    -maxdepth 2 \
    -type d \
    -name '*.app' \
    -print -quit
)"

[[ -n "$APP_BUNDLE" && -d "$APP_BUNDLE" ]] || {
  find "$EXPORT_DIR" -maxdepth 3 -print
  fail "No exported .app was found."
}

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"

[[ -f "$INFO_PLIST" ]] ||
  fail "The exported app has no Info.plist."

BUNDLE_ID="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleIdentifier' \
    "$INFO_PLIST" 2>/dev/null || true
)"

[[ -n "$BUNDLE_ID" ]] ||
  fail "Could not determine CFBundleIdentifier."

# ------------------------------------------------------------
# 12. Verify signing
# ------------------------------------------------------------

say "Verifying Developer ID signing"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

SIGNATURE_INFO="$(
  codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 || true
)"

if ! printf '%s\n' "$SIGNATURE_INFO" |
  grep -Fq 'Authority=Developer ID Application:'; then

  printf '%s\n' "$SIGNATURE_INFO"

  fail "The exported app does not have a Developer ID Application signature."
fi

# ------------------------------------------------------------
# 13. Verify universal architecture support
# ------------------------------------------------------------

say "Checking all bundled native executables"

MACHO_COUNT=0
ARCH_FAILURE=0

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
    printf '\nARCHITECTURE ERROR: %s\n' "$FILE_PATH" >&2
    printf 'Found: %s\n' "${ARCHS:-unknown}" >&2
    printf 'Missing:%s\n' "$MISSING" >&2

    ARCH_FAILURE=1
  fi

done < <(find "$APP_BUNDLE/Contents" -type f -print0)

(( MACHO_COUNT > 0 )) ||
  fail "No Mach-O executables were found."

(( ARCH_FAILURE == 0 )) ||
  fail "Universal build validation failed. Fix the native dependencies listed above."

say "Universal architecture validation passed"

# ------------------------------------------------------------
# 14. Notarize the exported application
# ------------------------------------------------------------

say "Preparing app for Apple notarization"

ditto \
  -c -k \
  --sequesterRsrc \
  --keepParent \
  "$APP_BUNDLE" \
  "$APP_ZIP"

say "Submitting the app to Apple"

xcrun notarytool submit "$APP_ZIP" \
  --keychain-profile "$MACOS_NOTARY_PROFILE" \
  --wait

say "Stapling the app notarization ticket"

xcrun stapler staple "$APP_BUNDLE"

xcrun stapler validate "$APP_BUNDLE"

# ------------------------------------------------------------
# 15. Stage the installer
# ------------------------------------------------------------

say "Staging the application for the DMG"

APP_BASENAME="$(basename "$APP_BUNDLE")"
STAGED_APP="$STAGING_DIR/$APP_BASENAME"

ditto "$APP_BUNDLE" "$STAGED_APP"

ln -s /Applications "$STAGING_DIR/Applications"

# ------------------------------------------------------------
# 16. Create the DMG
# ------------------------------------------------------------

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

# ------------------------------------------------------------
# 17. Sign the DMG
# ------------------------------------------------------------

say "Signing the disk image"

codesign \
  --force \
  --sign "$MACOS_SIGNING_IDENTITY" \
  --timestamp \
  -i "${BUNDLE_ID}.dmg" \
  "$DMG_PATH"

codesign --verify --verbose=2 "$DMG_PATH"

# ------------------------------------------------------------
# 18. Notarize the completed DMG
# ------------------------------------------------------------

say "Submitting the DMG to Apple"

xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$MACOS_NOTARY_PROFILE" \
  --wait

say "Stapling the DMG notarization ticket"

xcrun stapler staple "$DMG_PATH"

xcrun stapler validate "$DMG_PATH"

hdiutil verify "$DMG_PATH"

# ------------------------------------------------------------
# 19. Final distribution checks
# ------------------------------------------------------------

say "Checking Gatekeeper acceptance for the app"

spctl --assess \
  --type execute \
  --verbose=2 \
  "$STAGED_APP"

say "Checking Gatekeeper acceptance for the DMG"

spctl --assess \
  --type open \
  --context context:primary-signature \
  --verbose=2 \
  "$DMG_PATH"

# ------------------------------------------------------------
# 20. Success
# ------------------------------------------------------------

printf '\n============================================================\n'
printf ' DISTRIBUTION RELEASE COMPLETE\n'
printf ' Configuration: Release\n'
printf ' Architectures: arm64 + x86_64\n'
printf ' Signing:       Developer ID Application\n'
printf ' Notarization:  Completed and stapled\n'
printf ' DMG:           %s\n' "$DMG_PATH"
printf '============================================================\n'

printf '\nOpen the DMG and drag the application into Applications.\n'
printf 'Keep the DMG for distribution. Do not distribute the old build.\n'
printf '\n'
