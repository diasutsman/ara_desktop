#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# ARA ASSESSMENT
# Production macOS Release PKG & DMG Builder
#
# Build configuration: Release
# Architectures: arm64 + x86_64 (Universal 2)
# App & DMG Signing: Developer ID Application
# PKG Signing: Developer ID Installer (auto-detected)
# Distribution: Apple notarization + stapler
# Default Install Location: /Applications (Non-relocatable)
#
# NO fallback to Apple Development or ad-hoc signing for .app.
# ============================================================

APP_NAME="ARA Assessment"
APP_BUNDLE_NAME="${APP_NAME}.app"

MACOS_SIGNING_IDENTITY="${MACOS_SIGNING_IDENTITY:-}"
MACOS_INSTALLER_SIGNING_IDENTITY="${MACOS_INSTALLER_SIGNING_IDENTITY:-}"
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

for TOOL in flutter xcodebuild xcrun codesign lipo hdiutil ditto plutil pkgbuild productbuild productsign pkgutil; do
  if ! command -v "$TOOL" >/dev/null 2>&1; then
    # Flutter may be supplied by FVM, so check it separately below.
    [[ "$TOOL" == "flutter" ]] && continue
    fail "Missing required tool: $TOOL. Check your Xcode and Command Line Tools installation."
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

# Clean numeric version for pkgbuild/productbuild (strip +build suffix)
PKG_VERSION="${VERSION%%+*}"
[[ -n "$PKG_VERSION" ]] || PKG_VERSION="1.0.0"

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

PKG_BUILD_DIR="$TEMP_ROOT/pkg_build"
PKG_ROOT="$PKG_BUILD_DIR/root"
PKG_SCRIPTS_DIR="$PKG_BUILD_DIR/scripts"
COMPONENT_PLIST="$PKG_BUILD_DIR/Component.plist"
COMPONENT_PKG_NAME="ARA_Assessment_Component.pkg"
COMPONENT_PKG_PATH="$PKG_BUILD_DIR/$COMPONENT_PKG_NAME"
DISTRIBUTION_XML="$PKG_BUILD_DIR/Distribution.xml"
UNSIGNED_PKG_PATH="$PKG_BUILD_DIR/ARA_Assessment_Unsigned.pkg"
EXPANDED_PKG_DIR="$TEMP_ROOT/pkg_expanded"

APP_ZIP="$TEMP_ROOT/ARA_Assessment_notarization.zip"
PKG_PATH="$OUTPUT_DIR/ARA_Assessment_${VERSION_SAFE}.pkg"
DMG_PATH="$OUTPUT_DIR/ARA_Assessment_${VERSION_SAFE}.dmg"

mkdir -p "$OUTPUT_DIR" "$EXPORT_DIR" "$STAGING_DIR" "$PKG_ROOT" "$PKG_SCRIPTS_DIR"

cleanup() {
  if [[ -n "${TEMP_ROOT:-}" && -d "$TEMP_ROOT" ]]; then
    rm -rf "$TEMP_ROOT"
  fi
}

trap cleanup EXIT

# ------------------------------------------------------------
# 5. Require Developer ID Application & Detect Installer Cert
# ------------------------------------------------------------

say "Checking distribution certificates"

CODESIGN_IDENTITIES="$(
  security find-identity -v -p codesigning 2>/dev/null || true
)"

ALL_IDENTITIES="$(
  security find-identity -v 2>/dev/null || true
)"

# Automatically select Developer ID Application.
if [[ -z "$MACOS_SIGNING_IDENTITY" ]]; then
  MACOS_SIGNING_IDENTITY="$(
    printf '%s\n' "$CODESIGN_IDENTITIES" |
      sed -n \
        's/.*"\(Developer ID Application:.*\)".*/\1/p' |
      head -n 1 || true
  )"
fi

if [[ -z "$MACOS_SIGNING_IDENTITY" ]]; then
  printf '\nAvailable code signing identities:\n'
  printf '%s\n' "${CODESIGN_IDENTITIES:-None}"

  fail "Developer ID Application is missing. Apple Development is not a substitute for a public distribution certificate."
fi

[[ "$MACOS_SIGNING_IDENTITY" == "Developer ID Application:"* ]] ||
  fail "MACOS_SIGNING_IDENTITY must start with Developer ID Application:"

IDENTITY_LINE="$(
  printf '%s\n' "$CODESIGN_IDENTITIES" |
    grep -F "\"$MACOS_SIGNING_IDENTITY\"" |
    head -n 1 || true
)"

[[ -n "$IDENTITY_LINE" ]] ||
  fail "The selected Developer ID Application identity is not valid in the Keychain."

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

# Automatically detect Developer ID Installer certificate (for .pkg signing).
# Note: Do NOT pass `-p codesigning` when querying Installer certificates.
if [[ -z "$MACOS_INSTALLER_SIGNING_IDENTITY" ]]; then
  MACOS_INSTALLER_SIGNING_IDENTITY="$(
    printf '%s\n' "$ALL_IDENTITIES" |
      sed -n "s/.*\"\(Developer ID Installer:.*(${DEVELOPMENT_TEAM})\)\".*/\1/p" |
      head -n 1 || true
  )"
fi

if [[ -z "$MACOS_INSTALLER_SIGNING_IDENTITY" ]]; then
  MACOS_INSTALLER_SIGNING_IDENTITY="$(
    printf '%s\n' "$ALL_IDENTITIES" |
      sed -n 's/.*"\(Developer ID Installer:.*\)".*/\1/p' |
      head -n 1 || true
  )"
fi

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
printf ' Application:      %s\n' "$APP_NAME"
printf ' Version:          %s (PKG: %s)\n' "$VERSION" "$PKG_VERSION"
printf ' Configuration:    Release\n'
printf ' Architectures:    arm64 + x86_64\n'
printf ' App Signing:      %s\n' "$MACOS_SIGNING_IDENTITY"
printf ' PKG Signing:      %s\n' "${MACOS_INSTALLER_SIGNING_IDENTITY:-Not found in Keychain (unsigned outer PKG)}"
printf ' Team ID:          %s\n' "$DEVELOPMENT_TEAM"
printf ' Notary profile:   %s\n' "$MACOS_NOTARY_PROFILE"
printf ' Install Target:   /Applications/%s (Non-relocatable)\n' "$APP_BUNDLE_NAME"
printf ' PKG Output:       %s\n' "$PKG_PATH"
printf ' DMG Output:       %s\n' "$DMG_PATH"
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

EXPORTED_APP_BUNDLE="$(
  find "$EXPORT_DIR" \
    -maxdepth 2 \
    -type d \
    -name '*.app' \
    -print -quit
)"

[[ -n "$EXPORTED_APP_BUNDLE" && -d "$EXPORTED_APP_BUNDLE" ]] || {
  find "$EXPORT_DIR" -maxdepth 3 -print
  fail "No exported .app was found."
}

# Ensure the bundle directory name is "ARA Assessment.app" so it installs
# cleanly as "/Applications/ARA Assessment.app" (renaming the outer .app
# directory preserves the cryptographic seal over Contents/).
APP_BUNDLE="$EXPORT_DIR/$APP_BUNDLE_NAME"
if [[ "$EXPORTED_APP_BUNDLE" != "$APP_BUNDLE" ]]; then
  mv "$EXPORTED_APP_BUNDLE" "$APP_BUNDLE"
fi

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
# 15. Build PKG Installer (Auto-installs to /Applications)
# ------------------------------------------------------------

say "Staging payload for macOS PKG installer (/Applications)"

ditto "$APP_BUNDLE" "$PKG_ROOT/$APP_BUNDLE_NAME"

say "Generating non-relocatable Component.plist via pkgbuild --analyze"

pkgbuild \
  --analyze \
  --root "$PKG_ROOT" \
  "$COMPONENT_PLIST"

[[ -f "$COMPONENT_PLIST" ]] ||
  fail "pkgbuild --analyze did not generate Component.plist."

# Disable BundleIsRelocatable on all analyzed bundles so macOS Installer
# NEVER relocates the app to an old build/Downloads/DerivedData path and
# ALWAYS installs directly into /Applications.
BUNDLE_INDEX=0
while /usr/libexec/PlistBuddy -c "Print :${BUNDLE_INDEX}:RootRelativeBundlePath" "$COMPONENT_PLIST" >/dev/null 2>&1; do
  /usr/libexec/PlistBuddy -c "Set :${BUNDLE_INDEX}:BundleIsRelocatable false" "$COMPONENT_PLIST" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Add :${BUNDLE_INDEX}:BundleIsRelocatable bool false" "$COMPONENT_PLIST"

  /usr/libexec/PlistBuddy -c "Set :${BUNDLE_INDEX}:BundleIsVersionChecked false" "$COMPONENT_PLIST" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Add :${BUNDLE_INDEX}:BundleIsVersionChecked bool false" "$COMPONENT_PLIST"

  /usr/libexec/PlistBuddy -c "Set :${BUNDLE_INDEX}:BundleHasStrictIdentifier true" "$COMPONENT_PLIST" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Add :${BUNDLE_INDEX}:BundleHasStrictIdentifier bool true" "$COMPONENT_PLIST"

  /usr/libexec/PlistBuddy -c "Set :${BUNDLE_INDEX}:BundleOverwriteAction upgrade" "$COMPONENT_PLIST" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Add :${BUNDLE_INDEX}:BundleOverwriteAction string upgrade" "$COMPONENT_PLIST"

  BUNDLE_INDEX=$((BUNDLE_INDEX + 1))
done

(( BUNDLE_INDEX > 0 )) ||
  fail "Component.plist contained no bundle entries."

RELOCATABLE_CHECK="$(
  /usr/libexec/PlistBuddy -c "Print :0:BundleIsRelocatable" "$COMPONENT_PLIST" 2>/dev/null || true
)"
[[ "$RELOCATABLE_CHECK" == "false" ]] ||
  fail "BundleIsRelocatable is not false in Component.plist (got: ${RELOCATABLE_CHECK:-empty})."

plutil -lint "$COMPONENT_PLIST" >/dev/null

say "Creating PKG preinstall and postinstall scripts"

cat > "$PKG_SCRIPTS_DIR/preinstall" <<EOF
#!/usr/bin/env bash
set -euo pipefail

# Close any running instance before upgrading in /Applications.
/usr/bin/killall "ARA Assessment" >/dev/null 2>&1 || true
/usr/bin/killall "ara_desktop" >/dev/null 2>&1 || true

# Forget any previous package receipts that could cause PackageKit relocation.
/usr/sbin/pkgutil --forget "${BUNDLE_ID}" >/dev/null 2>&1 || true
/usr/sbin/pkgutil --forget "${BUNDLE_ID}.pkg" >/dev/null 2>&1 || true

# Clean up legacy bundle name if an older build installed ara_desktop.app.
if [[ -d "/Applications/ara_desktop.app" ]]; then
  /bin/rm -rf "/Applications/ara_desktop.app" || true
fi

exit 0
EOF

cat > "$PKG_SCRIPTS_DIR/postinstall" <<EOF
#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE_NAME="${APP_BUNDLE_NAME}"
TARGET_DIR="/Applications"
FINAL_APP="\${TARGET_DIR}/\${APP_BUNDLE_NAME}"
INSTALL_DEST="\${2:-/Applications}"

/bin/mkdir -p "\$TARGET_DIR"

# Guarantee the app bundle is placed inside /Applications even if PackageKit
# passed a different destination in \$2.
if [[ "\$INSTALL_DEST" != "\$TARGET_DIR" && -d "\${INSTALL_DEST}/\${APP_BUNDLE_NAME}" ]]; then
  /bin/rm -rf "\$FINAL_APP"
  /usr/bin/ditto "\${INSTALL_DEST}/\${APP_BUNDLE_NAME}" "\$FINAL_APP"
fi

if [[ ! -d "\$FINAL_APP" ]]; then
  echo "ERROR: Expected app bundle at \$FINAL_APP was not found after install." >&2
  exit 1
fi

/usr/sbin/chown -R root:wheel "\$FINAL_APP" || true
/bin/chmod -R a+rX "\$FINAL_APP" || true
/usr/bin/xattr -dr com.apple.quarantine "\$FINAL_APP" 2>/dev/null || true

# Register with LaunchServices so it appears immediately in /Applications,
# Spotlight, and Launchpad on modern macOS (Sonoma / Sequoia / Tahoe).
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "\$LSREGISTER" ]]; then
  "\$LSREGISTER" -f "\$FINAL_APP" >/dev/null 2>&1 || true
fi

exit 0
EOF

chmod 0755 "$PKG_SCRIPTS_DIR/preinstall" "$PKG_SCRIPTS_DIR/postinstall"

say "Building component package with pkgbuild (target: /Applications)"

PKG_IDENTIFIER="${BUNDLE_ID}.pkg"

pkgbuild \
  --root "$PKG_ROOT" \
  --component-plist "$COMPONENT_PLIST" \
  --scripts "$PKG_SCRIPTS_DIR" \
  --identifier "$PKG_IDENTIFIER" \
  --version "$PKG_VERSION" \
  --install-location "/Applications" \
  "$COMPONENT_PKG_PATH"

[[ -f "$COMPONENT_PKG_PATH" ]] ||
  fail "Component PKG was not created."

say "Generating Distribution.xml locked to Local System (/Applications)"

# Lock <domains> strictly to enable_localSystem="true" with
# enable_currentUserHome="false" and enable_anywhere="false", plus
# rootVolumeOnly="true" and customize="never".
# This forces macOS Installer to default directly to /Applications without
# asking the user to manually change the install location.
cat > "$DISTRIBUTION_XML" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>${APP_NAME}</title>
  <organization>${BUNDLE_ID}</organization>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <options customize="never" require-scripts="false" rootVolumeOnly="true" hostArchitectures="arm64,x86_64"/>
  <choices-outline>
    <line choice="default">
      <line choice="${PKG_IDENTIFIER}"/>
    </line>
  </choices-outline>
  <choice id="default"/>
  <choice id="${PKG_IDENTIFIER}" visible="false" enabled="true" selected="true" customLocation="/Applications">
    <pkg-ref id="${PKG_IDENTIFIER}"/>
  </choice>
  <pkg-ref id="${PKG_IDENTIFIER}" version="${PKG_VERSION}" onConclusion="none" auth="root">${COMPONENT_PKG_NAME}</pkg-ref>
</installer-gui-script>
XML

xmllint --noout "$DISTRIBUTION_XML" >/dev/null 2>&1 || true

say "Building product archive PKG with productbuild"

rm -f "$UNSIGNED_PKG_PATH" "$PKG_PATH"

productbuild \
  --distribution "$DISTRIBUTION_XML" \
  --package-path "$PKG_BUILD_DIR" \
  --identifier "${BUNDLE_ID}.installer" \
  --version "$PKG_VERSION" \
  "$UNSIGNED_PKG_PATH"

[[ -f "$UNSIGNED_PKG_PATH" ]] ||
  fail "Product PKG was not created."

say "Verifying PKG internal PackageInfo and Distribution rules"

pkgutil --expand "$UNSIGNED_PKG_PATH" "$EXPANDED_PKG_DIR"

PACKAGE_INFO_FILE="$(
  find "$EXPANDED_PKG_DIR" -name 'PackageInfo' -print -quit
)"

[[ -n "$PACKAGE_INFO_FILE" && -f "$PACKAGE_INFO_FILE" ]] ||
  fail "Could not locate PackageInfo inside expanded PKG."

grep -Fq 'install-location="/Applications"' "$PACKAGE_INFO_FILE" || {
  cat "$PACKAGE_INFO_FILE" >&2
  fail "PKG PackageInfo does not have install-location=\"/Applications\"."
}

if tr -d '\n\r' < "$PACKAGE_INFO_FILE" | grep -Eq '<relocate>[[:space:]]*<bundle'; then
  cat "$PACKAGE_INFO_FILE" >&2
  fail "PKG still has bundle relocation enabled (<relocate><bundle.../>)."
fi

grep -Fq 'enable_localSystem="true"' "$EXPANDED_PKG_DIR/Distribution" ||
  fail "PKG Distribution XML is missing enable_localSystem=\"true\"."

grep -Fq 'enable_currentUserHome="false"' "$EXPANDED_PKG_DIR/Distribution" ||
  fail "PKG Distribution XML is missing enable_currentUserHome=\"false\"."

grep -Fq 'enable_anywhere="false"' "$EXPANDED_PKG_DIR/Distribution" ||
  fail "PKG Distribution XML is missing enable_anywhere=\"false\"."

PKG_SIGNED_AND_NOTARIZED=0

if [[ -n "$MACOS_INSTALLER_SIGNING_IDENTITY" ]]; then
  say "Signing PKG installer with Developer ID Installer"

  productsign \
    --sign "$MACOS_INSTALLER_SIGNING_IDENTITY" \
    --timestamp \
    "$UNSIGNED_PKG_PATH" \
    "$PKG_PATH"

  pkgutil --check-signature "$PKG_PATH"

  say "Submitting the PKG to Apple for notarization"

  xcrun notarytool submit "$PKG_PATH" \
    --keychain-profile "$MACOS_NOTARY_PROFILE" \
    --wait

  say "Stapling the PKG notarization ticket"

  xcrun stapler staple "$PKG_PATH"

  xcrun stapler validate "$PKG_PATH"

  say "Checking Gatekeeper acceptance for the PKG"

  spctl --assess \
    --type install \
    --context context:primary-signature \
    --verbose=2 \
    "$PKG_PATH"

  PKG_SIGNED_AND_NOTARIZED=1
else
  cp "$UNSIGNED_PKG_PATH" "$PKG_PATH"
  printf '\nWARNING: No "Developer ID Installer:" certificate was found in the Keychain.\n'
  printf 'The inner "%s" inside %s IS signed, notarized, and stapled,\n' "$APP_BUNDLE_NAME" "$(basename "$PKG_PATH")"
  printf 'and the PKG will install automatically into /Applications.\n'
  printf 'To also sign and notarize the outer .pkg file for Gatekeeper on other Macs,\n'
  printf 'create a "Developer ID Installer" certificate at https://developer.apple.com/account/resources/certificates/list\n'
  printf 'and install it into your Keychain.\n'
fi

# ------------------------------------------------------------
# 16. Stage the DMG installer
# ------------------------------------------------------------

say "Staging the application for the DMG"

STAGED_APP="$STAGING_DIR/$APP_BUNDLE_NAME"

ditto "$APP_BUNDLE" "$STAGED_APP"

# If the PKG is signed and notarized with Developer ID Installer, include it inside
# the DMG as well so users can either run the PKG wizard or drag-and-drop.
if [[ "$PKG_SIGNED_AND_NOTARIZED" == "1" ]]; then
  ditto "$PKG_PATH" "$STAGING_DIR/$(basename "$PKG_PATH")"
fi

ln -s /Applications "$STAGING_DIR/Applications"

# ------------------------------------------------------------
# 17. Create the DMG
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
# 18. Sign the DMG
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
# 19. Notarize the completed DMG
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
# 20. Final distribution checks
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
# 21. Success
# ------------------------------------------------------------

printf '\n============================================================\n'
printf ' DISTRIBUTION RELEASE COMPLETE\n'
printf ' Configuration:   Release\n'
printf ' Architectures:   arm64 + x86_64\n'
printf ' App Signing:     Developer ID Application\n'
if [[ "$PKG_SIGNED_AND_NOTARIZED" == "1" ]]; then
  printf ' PKG Signing:     Developer ID Installer (Notarized & Stapled)\n'
else
  printf ' PKG Signing:     Inner App Notarized (Install "Developer ID Installer" cert to sign outer PKG)\n'
fi
printf ' Install Target:  /Applications/%s (Automatic, Non-relocatable)\n' "$APP_BUNDLE_NAME"
printf ' PKG Installer:   %s\n' "$PKG_PATH"
printf ' DMG Disk Image:  %s\n' "$DMG_PATH"
printf '============================================================\n'

printf '\nUse the PKG installer (%s) to automatically install "%s" directly into /Applications without manual location changes.\n' "$(basename "$PKG_PATH")" "$APP_BUNDLE_NAME"
printf '\n'
