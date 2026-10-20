#!/bin/bash
set -e

# Disable MSYS/Git Bash automatic POSIX-to-Windows path conversion for CLI switches (e.g. /DMyAppVersion)
export MSYS_NO_PATHCONV=1

# Get the absolute path to the directory containing this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

# Extract version from pubspec.yaml
VERSION=$(grep '^version:' "$PROJECT_ROOT/pubspec.yaml" | head -n 1 | awk '{print $2}' | tr -d '\r')
if [ -z "$VERSION" ]; then
  VERSION="1.0.0+1"
fi

echo "=========================================================="
echo " Building ARA Assessment Windows Release & Installer"
echo " Version: $VERSION"
echo "=========================================================="

echo "==> Running Flutter build windows (release)..."
fvm flutter build windows --release

echo "==> Detecting Inno Setup Compiler (ISCC)..."
ISCC_CMD=""
if command -v iscc >/dev/null 2>&1; then
  ISCC_CMD="iscc"
elif [ -f "$HOME/AppData/Local/Programs/Inno Setup 6/ISCC.exe" ]; then
  ISCC_CMD="$HOME/AppData/Local/Programs/Inno Setup 6/ISCC.exe"
elif [ -f "/c/Program Files (x86)/Inno Setup 6/ISCC.exe" ]; then
  ISCC_CMD="/c/Program Files (x86)/Inno Setup 6/ISCC.exe"
elif [ -f "/c/Program Files/Inno Setup 6/ISCC.exe" ]; then
  ISCC_CMD="/c/Program Files/Inno Setup 6/ISCC.exe"
else
  echo "ERROR: Inno Setup compiler (ISCC.exe) not found."
  echo "Please install Inno Setup 6 from https://jrsoftware.org/isdl.php"
  exit 1
fi

echo "==> Compiling Windows Installer with Inno Setup..."
"$ISCC_CMD" "/DMyAppVersion=$VERSION" inno_setup.iss

SETUP_FILE="$PROJECT_ROOT/build/windows/ARA_Assessment_Setup.exe"
if [ -f "$SETUP_FILE" ]; then
  echo ""
  echo "=========================================================="
  echo " [SUCCESS] Windows Installer created successfully!"
  echo " Output: $SETUP_FILE"
  echo "=========================================================="
else
  echo "Warning: Build completed, but $SETUP_FILE was not found."
fi
