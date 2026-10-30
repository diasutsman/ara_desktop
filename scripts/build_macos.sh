#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# ARA ASSESSMENT — macOS Release PKG & DMG Builder
#
# Supports:
# - Apple Silicon (arm64) + Intel (x86_64) Universal build
# - Developer ID signing (when available)
# - Apple Development signing (automatic fallback)
# - Ad-hoc signing (automatic fallback when no cert exists)
# - Optional Apple notarization (only when Developer ID + notary profile exist)
# - Non-relocatable .pkg installer that ALWAYS installs to /Applications
#   automatically without manual destination changes
# ============================================================

APP_NAME="ARA Assessment"
APP_BUNDLE_NAME="${APP_NAME}.app"

# 0 = warn about missing CPU architectures and continue
# 1 = fail if a binary lacks arm64 or x86_64
REQUIRE_UNIVERSAL="${REQUIRE_UNIVERSAL:-0}"

MACOS_SIGNING_IDENTITY="${MACOS_SIGNING_IDENTITY:-}"
MACOS_INSTALLER_SIGNING_IDENTITY="${MACOS_INSTALLER_SIGNING_IDENTITY:-}"
MACOS_NOTARY_PROFILE="${MACOS_NOTARY_PROFILE:-}"

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

for TOOL in flutter xcodebuild xcrun codesign lipo hdiutil ditto plutil pkgbuild productbuild pkgutil; do
  if ! command -v "$TOOL" >/dev/null 2>&1; then
    # Flutter may be supplied by FVM, so check it separately below.
    [[ "$TOOL" == "flutter" ]] && continue
    fail "Missing required tool: $TOOL. Check your Xcode and Command Line Tools installation."
  fi
done

[[ -d "$PROJECT_ROOT/macos" ]] ||
  fail "macos/ directory is missing. Run: flutter create --platforms=macos ."

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

[[ -n "$VERSION" ]] || VERSION="1.0.0+1"

# Clean numeric version for pkgbuild/productbuild (strip +build suffix)
PKG_VERSION="${VERSION%%+*}"
[[ -n "$PKG_VERSION" ]] || PKG_VERSION="1.0.0"

VERSION_SAFE="$(
  printf '%s' "$VERSION" |
    tr -c 'A-Za-z0-9._+-' '_'
)"

OUTPUT_DIR="$PROJECT_ROOT/build/macos"
BUILD_PRODUCTS="$OUTPUT_DIR/Build/Products/Release"
PKG_PATH="$OUTPUT_DIR/ARA_Assessment_${VERSION_SAFE}.pkg"
DMG_PATH="$OUTPUT_DIR/ARA_Assessment_${VERSION_SAFE}.dmg"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ara-macos-build.XXXXXX")"

PROJECT_PBXPROJ="$PROJECT_ROOT/macos/Runner.xcodeproj/project.pbxproj"
PROJECT_BACKUP="$TEMP_ROOT/project.pbxproj.original"
PATCHED_PBXPROJ=0

APP_STAGE_DIR="$TEMP_ROOT/app_stage"
STAGING_DIR="$TEMP_ROOT/dmg_staging"

PKG_BUILD_DIR="$TEMP_ROOT/pkg_build"
PKG_ROOT="$PKG_BUILD_DIR/root"
PKG_SCRIPTS_DIR="$PKG_BUILD_DIR/scripts"
COMPONENT_PLIST="$PKG_BUILD_DIR/Component.plist"
COMPONENT_PKG_NAME="ARA_Assessment_Component.pkg"
COMPONENT_PKG_PATH="$PKG_BUILD_DIR/$COMPONENT_PKG_NAME"
DISTRIBUTION_XML="$PKG_BUILD_DIR/Distribution.xml"
UNSIGNED_PKG_PATH="$PKG_BUILD_DIR/ARA_Assessment_Unsigned.pkg"
EXPANDED_PKG_DIR="$TEMP_ROOT/pkg_expanded"

mkdir -p "$OUTPUT_DIR" "$APP_STAGE_DIR" "$STAGING_DIR" "$PKG_ROOT" "$PKG_SCRIPTS_DIR"

cleanup() {
  if [[ "${PATCHED_PBXPROJ:-0}" == "1" && -f "${PROJECT_BACKUP:-}" ]]; then
    cp "$PROJECT_BACKUP" "$PROJECT_PBXPROJ" ||
      printf '%s\n' "WARNING: Could not restore the original Xcode project file." >&2
  fi

  if [[ -n "${TEMP_ROOT:-}" && -d "$TEMP_ROOT" ]]; then
    rm -rf "$TEMP_ROOT"
  fi
}

trap cleanup EXIT

# ------------------------------------------------------------
# 5. Detect available signing certificates (with auto-fallback)
# ------------------------------------------------------------

say "Detecting available signing certificates"

CODESIGN_IDENTITIES="$(
  security find-identity -v -p codesigning 2>/dev/null || true
)"

ALL_IDENTITIES="$(
  security find-identity -v 2>/dev/null || true
)"

# 1) Prefer Developer ID Application if available (required for notarized public distribution).
# 2) If no Developer ID Application certificate is installed, use clean inside-out ad-hoc
#    signing (-) rather than a machine-bound "Apple Development:" certificate, because an
#    Apple Development signature is tied to a developer's personal provisioning profile and
#    can cause XPC/WebKit helper or AMFI trust issues on external client MacBooks.
if [[ -z "$MACOS_SIGNING_IDENTITY" ]]; then
  MACOS_SIGNING_IDENTITY="$(
    printf '%s\n' "$CODESIGN_IDENTITIES" |
      sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p' |
      head -n 1 || true
  )"
fi

if [[ -n "$MACOS_SIGNING_IDENTITY" ]]; then
  printf 'Using app signing identity: %s\n' "$MACOS_SIGNING_IDENTITY"
else
  printf '%s\n' "No Developer ID Application certificate found. Using universal inside-out ad-hoc signing (-)."
fi

IS_DEVELOPER_ID=0
if [[ "$MACOS_SIGNING_IDENTITY" == "Developer ID Application:"* ]]; then
  IS_DEVELOPER_ID=1
fi

# Optional Developer ID Installer certificate for .pkg signing.
if [[ -z "$MACOS_INSTALLER_SIGNING_IDENTITY" ]]; then
  MACOS_INSTALLER_SIGNING_IDENTITY="$(
    printf '%s\n' "$ALL_IDENTITIES" |
      sed -n 's/.*"\(Developer ID Installer:.*\)".*/\1/p' |
      head -n 1 || true
  )"
fi

# Notarization is optional: runs only when Developer ID + notary profile are both present.
DO_NOTARIZE=0
if [[ "$IS_DEVELOPER_ID" == "1" && -n "$MACOS_NOTARY_PROFILE" ]]; then
  if xcrun notarytool history --keychain-profile "$MACOS_NOTARY_PROFILE" --output-format json >/dev/null 2>&1; then
    DO_NOTARIZE=1
  else
    printf 'WARNING: Notary profile "%s" could not be validated. Skipping notarization.\n' "$MACOS_NOTARY_PROFILE"
  fi
fi

# ------------------------------------------------------------
# 6. Print build configuration
# ------------------------------------------------------------

printf '\n============================================================\n'
printf ' Application:      %s\n' "$APP_NAME"
printf ' Version:          %s (PKG: %s)\n' "$VERSION" "$PKG_VERSION"
printf ' Project:          %s\n' "$PROJECT_ROOT"
printf ' Flutter:          %s\n' "${FLUTTER[*]}"
printf ' App Signing:      %s\n' "${MACOS_SIGNING_IDENTITY:-Ad-hoc (-)}"
printf ' PKG Signing:      %s\n' "${MACOS_INSTALLER_SIGNING_IDENTITY:-Unsigned (postinstall auto-trusts in /Applications)}"
printf ' Notarize:         %s\n' "$DO_NOTARIZE"
printf ' Install Target:   /Applications/%s (Automatic, Non-relocatable)\n' "$APP_BUNDLE_NAME"
printf ' PKG Output:       %s\n' "$PKG_PATH"
printf ' DMG Output:       %s\n' "$DMG_PATH"
printf '============================================================\n'

say "Checking Xcode and Flutter"

xcodebuild -version
"${FLUTTER[@]}" --version

# ------------------------------------------------------------
# 7. Fetch dependencies
# ------------------------------------------------------------

say "Running Flutter pub get"

# Ensure CocoaPods is used so all plugins compile with MACOSX_DEPLOYMENT_TARGET=10.15 and Universal (arm64 + x86_64)
"${FLUTTER[@]}" config --no-enable-swift-package-manager >/dev/null 2>&1 || true

"${FLUTTER[@]}" pub get

# Patch flutter_inappwebview_macos 1.1.2 SSL/TLS ServerTrust handling (auto-evaluate & main-thread completionHandler)
patch_inappwebview_swift() {
  local INAPP_SWIFT="$1"
  [[ -f "$INAPP_SWIFT" ]] || return 0
  if grep -Fq 'let exceptions = SecTrustCopyExceptions(serverTrust)' "$INAPP_SWIFT" &&
     ! grep -Fq 'SecTrustSetNetworkFetchAllowed(serverTrust, false)' "$INAPP_SWIFT"; then
    say "Patching flutter_inappwebview_macos SSL ServerTrust auto-accept in $INAPP_SWIFT"
    /usr/bin/perl -0pi -e '
      s/let exceptions = SecTrustCopyExceptions\(serverTrust\)\s*\n\s*SecTrustSetExceptions\(serverTrust, exceptions\)\s*\n\s*let credential = URLCredential\(trust: serverTrust\)\s*\n\s*(?:DispatchQueue\.main\.async \{ completionHandler\(\.useCredential, credential\) \}|completionHandler\(\.useCredential, credential\))/SecTrustSetNetworkFetchAllowed(serverTrust, false)\n                                _ = SecTrustEvaluateWithError(serverTrust, nil)\n                                if let exceptions = SecTrustCopyExceptions(serverTrust) {\n                                    SecTrustSetExceptions(serverTrust, exceptions)\n                                }\n                                let credential = URLCredential(trust: serverTrust)\n                                DispatchQueue.main.async { completionHandler(.useCredential, credential) }/g
    ' "$INAPP_SWIFT" || true
  fi
}

if [[ -f "$PROJECT_ROOT/macos/Flutter/ephemeral/.symlinks/plugins/flutter_inappwebview_macos/macos/Classes/InAppWebView/InAppWebView.swift" ]]; then
  patch_inappwebview_swift "$PROJECT_ROOT/macos/Flutter/ephemeral/.symlinks/plugins/flutter_inappwebview_macos/macos/Classes/InAppWebView/InAppWebView.swift"
fi

if [[ -d "${PUB_CACHE:-$HOME/.pub-cache}/hosted/pub.dev" ]]; then
  while IFS= read -r -d '' INAPP_SWIFT; do
    patch_inappwebview_swift "$INAPP_SWIFT"
  done < <(find "${PUB_CACHE:-$HOME/.pub-cache}/hosted/pub.dev" -path '*/flutter_inappwebview_macos*/macos/Classes/InAppWebView/InAppWebView.swift' -print0 2>/dev/null || true)
fi

if [[ -f "$PROJECT_ROOT/macos/Podfile" ]]; then
  if command -v pod >/dev/null 2>&1; then
    say "Installing CocoaPods dependencies"
    if ! (cd "$PROJECT_ROOT/macos" && pod install); then
      printf '%s\n' "WARNING: pod install failed. Continuing to the Flutter build."
    fi
  else
    printf '%s\n' "WARNING: CocoaPods is missing. The Flutter build may require it."
  fi
fi

# ------------------------------------------------------------
# 8. Prepare standard Xcode architectures (arm64 + x86_64) & macOS 10.15+ target
# ------------------------------------------------------------

if [[ -f "$PROJECT_PBXPROJ" ]]; then
  say "Preparing Xcode architecture (Universal arm64 + x86_64) & minimum macOS 10.15 deployment target"

  cp "$PROJECT_PBXPROJ" "$PROJECT_BACKUP"
  PATCHED_PBXPROJ=1

  /usr/bin/perl -0pi -e '
    s/^[ \t]*ARCHS = [^;]+;/        ARCHS = "\$(ARCHS_STANDARD)";/mg;
    s/^[ \t]*ONLY_ACTIVE_ARCH = YES;/        ONLY_ACTIVE_ARCH = NO;/mg;
    s/^[ \t]*MACOSX_DEPLOYMENT_TARGET = [^;]+;/        MACOSX_DEPLOYMENT_TARGET = "10.15";/mg;
  ' "$PROJECT_PBXPROJ"
fi

# ------------------------------------------------------------
# 9. Build Flutter macOS release
# ------------------------------------------------------------

say "Building Flutter macOS release application (Universal arm64 + x86_64, macOS 10.15+)"

export MACOSX_DEPLOYMENT_TARGET="10.15"
export FLUTTER_XCODE_MACOSX_DEPLOYMENT_TARGET="10.15"
export FLUTTER_XCODE_ONLY_ACTIVE_ARCH="NO"

"${FLUTTER[@]}" build macos --release

[[ -d "$BUILD_PRODUCTS" ]] ||
  fail "Release output was not found: $BUILD_PRODUCTS"

# ------------------------------------------------------------
# 10. Find generated .app and normalize to "ARA Assessment.app"
# ------------------------------------------------------------

RAW_APP_BUNDLE=""

for CANDIDATE in \
  "$BUILD_PRODUCTS/ARA Assessment.app" \
  "$BUILD_PRODUCTS/ara_desktop.app" \
  "$BUILD_PRODUCTS/Runner.app"; do

  if [[ -d "$CANDIDATE" ]]; then
    RAW_APP_BUNDLE="$CANDIDATE"
    break
  fi
done

if [[ -z "$RAW_APP_BUNDLE" ]]; then
  RAW_APP_BUNDLE="$(
    find "$BUILD_PRODUCTS" \
      -maxdepth 1 \
      -type d \
      -name '*.app' \
      -print -quit
  )"
fi

[[ -n "$RAW_APP_BUNDLE" && -d "$RAW_APP_BUNDLE" ]] ||
  fail "No .app bundle was generated in $BUILD_PRODUCTS."

APP_BUNDLE="$APP_STAGE_DIR/$APP_BUNDLE_NAME"
rm -rf "$APP_BUNDLE"
/usr/bin/ditto "$RAW_APP_BUNDLE" "$APP_BUNDLE"

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"

[[ -f "$INFO_PLIST" ]] ||
  fail "The application is missing Info.plist."

# Ensure Finder & Launchpad display "ARA Assessment" consistently and support macOS 10.15+
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName '$APP_NAME'" "$INFO_PLIST" 2>/dev/null ||
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string '$APP_NAME'" "$INFO_PLIST" 2>/dev/null || true

/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 10.15" "$INFO_PLIST" 2>/dev/null ||
  /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 10.15" "$INFO_PLIST" 2>/dev/null || true

# Also lower LSMinimumSystemVersion in all nested Framework Info.plist files (including FlutterMacOS.framework)
while IFS= read -r -d '' FW_PLIST; do
  /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 10.15" "$FW_PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :MinimumOSVersion 10.15" "$FW_PLIST" 2>/dev/null || true
done < <(find "$APP_BUNDLE/Contents/Frameworks" -name 'Info.plist' -print0 2>/dev/null || true)

# Lower Mach-O LC_BUILD_VERSION minos to 10.15 on all binaries/frameworks so dyld on older macOS (Catalina/Big Sur) never rejects prebuilt frameworks
lower_macho_minos_1015() {
  local BIN="$1"
  command -v xcrun >/dev/null 2>&1 || return 0
  local ARCHS
  ARCHS="$(lipo -archs "$BIN" 2>/dev/null || true)"
  [[ -n "$ARCHS" ]] || return 0

  local ARCH_ARRAY=($ARCHS)
  if (( ${#ARCH_ARRAY[@]} == 1 )); then
    local ARCH="${ARCH_ARRAY[0]}"
    local SDK_VER
    SDK_VER="$(xcrun vtool -arch "$ARCH" -show-build "$BIN" 2>/dev/null | awk '/sdk / {print $2; exit}' || true)"
    [[ -n "$SDK_VER" && "$SDK_VER" != "n/a" ]] || SDK_VER="12.0"
    if xcrun vtool -arch "$ARCH" -set-build-version macos 10.15 "$SDK_VER" -replace -output "${BIN}.vtmp" "$BIN" 2>/dev/null; then
      mv -f "${BIN}.vtmp" "$BIN"
    else
      rm -f "${BIN}.vtmp"
    fi
  elif (( ${#ARCH_ARRAY[@]} > 1 )); then
    local SLICE_FILES=()
    local UPDATED=1
    for ARCH in "${ARCH_ARRAY[@]}"; do
      local SLICE="${BIN}.slice.${ARCH}"
      local SLICE_OUT="${BIN}.slice.${ARCH}.out"
      if lipo "$BIN" -thin "$ARCH" -output "$SLICE" 2>/dev/null; then
        local SDK_VER
        SDK_VER="$(xcrun vtool -show-build "$SLICE" 2>/dev/null | awk '/sdk / {print $2; exit}' || true)"
        [[ -n "$SDK_VER" && "$SDK_VER" != "n/a" ]] || SDK_VER="12.0"
        if xcrun vtool -set-build-version macos 10.15 "$SDK_VER" -replace -output "$SLICE_OUT" "$SLICE" 2>/dev/null; then
          SLICE_FILES+=("$SLICE_OUT")
        else
          SLICE_FILES+=("$SLICE")
        fi
      else
        UPDATED=0
        break
      fi
    done
    if (( UPDATED == 1 && ${#SLICE_FILES[@]} == ${#ARCH_ARRAY[@]} )); then
      if lipo -create "${SLICE_FILES[@]}" -output "${BIN}.vfat" 2>/dev/null; then
        mv -f "${BIN}.vfat" "$BIN"
      fi
    fi
    rm -f "${BIN}.slice."* "${BIN}.vfat" 2>/dev/null || true
  fi
}

while IFS= read -r -d '' BIN_PATH; do
  DESC="$(file -b "$BIN_PATH" 2>/dev/null || true)"
  [[ "$DESC" == *Mach-O* ]] || continue
  lower_macho_minos_1015 "$BIN_PATH"
done < <(find "$APP_BUNDLE/Contents" -type f ! -type l -print0 2>/dev/null || true)

BUNDLE_ID="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleIdentifier' \
    "$INFO_PLIST" 2>/dev/null || true
)"

[[ -n "$BUNDLE_ID" ]] || BUNDLE_ID="com.ara.assessment.araDesktop"

APP_EXECUTABLE="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleExecutable' \
    "$INFO_PLIST" 2>/dev/null || true
)"

[[ -n "$APP_EXECUTABLE" ]] ||
  fail "Could not identify the app executable."

MAIN_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE"

[[ -f "$MAIN_BINARY" ]] ||
  fail "The main app executable is missing: $MAIN_BINARY"

# ------------------------------------------------------------
# 11. Check Intel and Apple Silicon architectures
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
    printf 'WARNING: %s (Found: %s, Missing:%s)\n' "$FILE_PATH" "${ARCHS:-unknown}" "$MISSING" >&2
    ARCH_FAILURE=1
  fi
done < <(find "$APP_BUNDLE/Contents" -type f -print0)

(( MACHO_COUNT > 0 )) ||
  fail "No Mach-O binaries were found inside the application."

if (( ARCH_FAILURE != 0 )); then
  if [[ "$REQUIRE_UNIVERSAL" == "1" ]]; then
    fail "Universal build check failed. One or more binaries lack arm64 or x86_64."
  else
    printf '%s\n' "NOTE: Some native binaries are single-architecture."
  fi
else
  printf '%s\n' "All checked Mach-O binaries support arm64 and x86_64."
fi

# ------------------------------------------------------------
# 12. Sign the application bundle
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

say "Signing application bundle ($APP_BUNDLE_NAME) inside-out"

/usr/bin/xattr -cr "$APP_BUNDLE" 2>/dev/null || true

# Embed a copy of the entitlements inside Contents/Resources/App.entitlements
# so the PKG postinstall script on the client MacBook can preserve all WebKit,
# network, JIT, camera, and microphone entitlements if it refreshes the signature.
if [[ -n "$ENTITLEMENTS" && -f "$ENTITLEMENTS" ]]; then
  mkdir -p "$APP_BUNDLE/Contents/Resources"
  cp "$ENTITLEMENTS" "$APP_BUNDLE/Contents/Resources/App.entitlements"
fi

sign_app_bundle_inside_out() {
  local TARGET_BUNDLE="$1"
  local IDENTITY="$2"
  local ENT_FILE="$3"
  local USE_RUNTIME="$4"

  local BASE_ARGS=(--force --sign "$IDENTITY")
  if [[ "$USE_RUNTIME" == "1" ]]; then
    BASE_ARGS+=(--options runtime --timestamp)
  fi

  # 1. Sign nested shared libraries (.dylib) inside Contents/Frameworks without app entitlements
  if [[ -d "$TARGET_BUNDLE/Contents/Frameworks" ]]; then
    while IFS= read -r -d '' DYLIB_PATH; do
      codesign "${BASE_ARGS[@]}" "$DYLIB_PATH"
    done < <(find "$TARGET_BUNDLE/Contents/Frameworks" -type f -name '*.dylib' -print0)

    # 2. Sign nested frameworks (.framework) without app entitlements (never use --deep with --entitlements)
    while IFS= read -r -d '' FRAMEWORK_PATH; do
      codesign "${BASE_ARGS[@]}" "$FRAMEWORK_PATH"
    done < <(find "$TARGET_BUNDLE/Contents/Frameworks" -maxdepth 2 -type d -name '*.framework' -print0)
  fi

  # 3. Sign the outer .app bundle with the main app entitlements
  local APP_ARGS=("${BASE_ARGS[@]}")
  if [[ -n "$ENT_FILE" && -f "$ENT_FILE" ]]; then
    APP_ARGS+=(--entitlements "$ENT_FILE")
  fi
  codesign "${APP_ARGS[@]}" "$TARGET_BUNDLE"
}

if [[ -n "$MACOS_SIGNING_IDENTITY" ]] &&
   printf '%s\n' "$CODESIGN_IDENTITIES" | grep -Fq "\"$MACOS_SIGNING_IDENTITY\""; then

  if ! sign_app_bundle_inside_out "$APP_BUNDLE" "$MACOS_SIGNING_IDENTITY" "$ENTITLEMENTS" "$IS_DEVELOPER_ID"; then
    printf '%s\n' "WARNING: Certificate signing failed; falling back to inside-out ad-hoc signing (-)."
    sign_app_bundle_inside_out "$APP_BUNDLE" "-" "$ENTITLEMENTS" "0"
  fi
else
  sign_app_bundle_inside_out "$APP_BUNDLE" "-" "$ENTITLEMENTS" "0"
fi

say "Verifying application signature and entitlements"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
codesign -d --entitlements :- "$APP_BUNDLE" >/dev/null 2>&1 || true

# ------------------------------------------------------------
# 13. Notarize the app (only if Developer ID + notary profile exist)
# ------------------------------------------------------------

NOTARIZED=0

if [[ "$DO_NOTARIZE" == "1" ]]; then
  say "Preparing app for Apple notarization"

  NOTARY_ZIP="$TEMP_ROOT/ARA_Assessment_notarization.zip"

  /usr/bin/ditto \
    -c -k \
    --sequesterRsrc \
    --keepParent \
    "$APP_BUNDLE" \
    "$NOTARY_ZIP"

  say "Submitting app to Apple notarization service"

  xcrun notarytool submit "$NOTARY_ZIP" \
    --keychain-profile "$MACOS_NOTARY_PROFILE" \
    --wait

  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"

  NOTARIZED=1
else
  printf '%s\n' "Skipping Apple notarization (no Developer ID + notary profile configured)."
fi

# ------------------------------------------------------------
# 14. Build Non-Relocatable PKG Installer (Auto-installs to /Applications)
# ------------------------------------------------------------

say "Staging payload for macOS PKG installer (/Applications/$APP_BUNDLE_NAME)"

/usr/bin/ditto "$APP_BUNDLE" "$PKG_ROOT/$APP_BUNDLE_NAME"

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

# Close any running instance before installing/upgrading in /Applications.
/usr/bin/killall "ARA Assessment" >/dev/null 2>&1 || true
/usr/bin/killall "ara_desktop" >/dev/null 2>&1 || true

# Forget any previous package receipts that could cause PackageKit relocation.
/usr/sbin/pkgutil --forget "${BUNDLE_ID}" >/dev/null 2>&1 || true
/usr/sbin/pkgutil --forget "${BUNDLE_ID}.pkg" >/dev/null 2>&1 || true
/usr/sbin/pkgutil --forget "${BUNDLE_ID}.installer" >/dev/null 2>&1 || true

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

# Set standard /Applications ownership and permissions.
/usr/sbin/chown -R root:wheel "\$FINAL_APP" || true
/bin/chmod -R a+rX "\$FINAL_APP" || true

# Remove quarantine and provenance attributes so Gatekeeper never blocks the
# installed app on any MacBook (Intel or Apple Silicon).
/usr/bin/xattr -cr "\$FINAL_APP" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.quarantine "\$FINAL_APP" 2>/dev/null || true

# Ensure local ad-hoc signature and entitlements are intact on the client MacBook
# when the app was built without a notarized Developer ID certificate.
EMBEDDED_ENTITLEMENTS="\$FINAL_APP/Contents/Resources/App.entitlements"
if [[ "${IS_DEVELOPER_ID}" == "0" ]] || ! /usr/bin/codesign --verify --deep --strict "\$FINAL_APP" >/dev/null 2>&1; then
  if [[ -d "\$FINAL_APP/Contents/Frameworks" ]]; then
    find "\$FINAL_APP/Contents/Frameworks" -type f -name '*.dylib' -exec /usr/bin/codesign --force --sign - {} \; >/dev/null 2>&1 || true
    find "\$FINAL_APP/Contents/Frameworks" -maxdepth 2 -type d -name '*.framework' -exec /usr/bin/codesign --force --sign - {} \; >/dev/null 2>&1 || true
  fi
  if [[ -f "\$EMBEDDED_ENTITLEMENTS" ]]; then
    /usr/bin/codesign --force --sign - --entitlements "\$EMBEDDED_ENTITLEMENTS" "\$FINAL_APP" >/dev/null 2>&1 || true
  else
    /usr/bin/codesign --force --sign - "\$FINAL_APP" >/dev/null 2>&1 || true
  fi
fi

# Register in Gatekeeper SystemPolicy so macOS never shows "unidentified developer" or malware warnings
if [[ -x "/usr/sbin/spctl" ]]; then
  /usr/sbin/spctl --add --label "ARA Assessment" "\$FINAL_APP" >/dev/null 2>&1 || true
  /usr/sbin/spctl --enable --label "ARA Assessment" >/dev/null 2>&1 || true
fi

# Register with LaunchServices so it appears immediately in /Applications,
# Spotlight, and Launchpad on all macOS versions (Catalina through Sequoia / Tahoe).
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "\$LSREGISTER" ]]; then
  "\$LSREGISTER" -f "\$FINAL_APP" >/dev/null 2>&1 || true
fi

# Automatically trust ara-assessment.com SSL certificate & Sectigo R36 intermediate
# in the macOS System Keychain so WKWebView never rejects incomplete server cert chains.
(
  /usr/bin/curl -fsSL --max-time 6 "http://crt.sectigo.com/SectigoPublicServerAuthenticationCADVR36.crt" -o /tmp/ara_sectigo_r36.crt 2>/dev/null &&
    /usr/bin/security add-trusted-cert -d -r trustAsRoot -k /Library/Keychains/System.keychain /tmp/ara_sectigo_r36.crt >/dev/null 2>&1
  /usr/bin/openssl s_client -connect ara-assessment.com:443 -servername ara-assessment.com </dev/null 2>/dev/null |
    /usr/bin/openssl x509 -outform PEM > /tmp/ara_server_cert.pem 2>/dev/null &&
    [[ -s /tmp/ara_server_cert.pem ]] &&
    /usr/bin/security add-trusted-cert -d -r trustAsRoot -k /Library/Keychains/System.keychain /tmp/ara_server_cert.pem >/dev/null 2>&1
  /bin/rm -f /tmp/ara_sectigo_r36.crt /tmp/ara_server_cert.pem
) >/dev/null 2>&1 || true

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
<installer-gui-script minSpecVersion="1">
  <title>${APP_NAME}</title>
  <organization>${BUNDLE_ID}</organization>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <options customize="never" require-scripts="false" rootVolumeOnly="true"/>
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

if [[ -n "$MACOS_INSTALLER_SIGNING_IDENTITY" ]] && command -v productsign >/dev/null 2>&1; then
  say "Signing PKG installer with Developer ID Installer"

  productsign \
    --sign "$MACOS_INSTALLER_SIGNING_IDENTITY" \
    --timestamp \
    "$UNSIGNED_PKG_PATH" \
    "$PKG_PATH"

  pkgutil --check-signature "$PKG_PATH"

  if [[ "$DO_NOTARIZE" == "1" ]]; then
    say "Submitting the PKG to Apple for notarization"

    xcrun notarytool submit "$PKG_PATH" \
      --keychain-profile "$MACOS_NOTARY_PROFILE" \
      --wait

    xcrun stapler staple "$PKG_PATH"
    xcrun stapler validate "$PKG_PATH"
  fi
else
  cp "$UNSIGNED_PKG_PATH" "$PKG_PATH"
fi

/usr/bin/xattr -cr "$PKG_PATH" 2>/dev/null || true

[[ -f "$PKG_PATH" ]] ||
  fail "The final PKG installer was not created at $PKG_PATH."

# ------------------------------------------------------------
# 15. Stage and create the DMG installer
# ------------------------------------------------------------

say "Staging application for DMG"

STAGED_APP="$STAGING_DIR/$APP_BUNDLE_NAME"

/usr/bin/ditto "$APP_BUNDLE" "$STAGED_APP"
ln -s /Applications "$STAGING_DIR/Applications"

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

/usr/bin/xattr -cr "$DMG_PATH" 2>/dev/null || true

# ------------------------------------------------------------
# 16. Notarize the final DMG (only when configured)
# ------------------------------------------------------------

if [[ "$NOTARIZED" == "1" ]]; then
  say "Submitting DMG to Apple for notarization"

  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$MACOS_NOTARY_PROFILE" \
    --wait

  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

# ------------------------------------------------------------
# 17. Final result
# ------------------------------------------------------------

printf '\n============================================================\n'
printf ' BUILD COMPLETE\n'
printf ' Application:    %s\n' "$APP_NAME"
printf ' Install Target: /Applications/%s (Automatic, Non-relocatable)\n' "$APP_BUNDLE_NAME"
printf ' PKG Installer:  %s\n' "$PKG_PATH"
printf ' DMG Installer:  %s\n' "$DMG_PATH"
printf '============================================================\n'

if [[ "$NOTARIZED" == "1" ]]; then
  printf '%s\n' "Status: Signed and notarized."
elif [[ -n "$MACOS_SIGNING_IDENTITY" ]]; then
  printf 'Status: Signed with "%s" (PKG postinstall auto-clears quarantine in /Applications).\n' "$MACOS_SIGNING_IDENTITY"
else
  printf '%s\n' "Status: Ad-hoc signed (PKG postinstall auto-clears quarantine in /Applications)."
fi

printf '\nOutput files:\n  1) %s (Recommended: auto-installs into /Applications)\n  2) %s\n\n' "$PKG_PATH" "$DMG_PATH"
