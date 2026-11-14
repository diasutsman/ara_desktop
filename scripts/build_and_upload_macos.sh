#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# ARA ASSESSMENT — One-Click macOS .pkg Builder & GitHub Release Uploader
#
# Jalankan di MacBook:
#   chmod +x scripts/build_and_upload_macos.sh
#   ./scripts/build_and_upload_macos.sh
#
# Script ini akan:
# 1. Memastikan GitHub Token tersedia di awal (dari env, macOS Keychain, atau input manual sekali)
# 2. Membaca versi dari pubspec.yaml (misal 1.0.6+7 -> v1.0.6)
# 3. Menjalankan scripts/build_macos.sh untuk membuat .pkg Universal
# 4. Menyalin/menamai file sesuai format: ARA_Assessment_Setup_v<semver>.pkg
# 5. Mengunggah langsung ke GitHub Release v<semver> (membuat release jika belum ada)
# ==============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

[[ "$(uname -s)" == "Darwin" ]] || {
  echo "ERROR: Script ini harus dijalankan di macOS." >&2
  exit 1
}

VERSION="$(awk -F': *' '/^version:/ {print $2; exit}' pubspec.yaml | tr -d '"\r')"
[[ -n "$VERSION" ]] || {
  echo "ERROR: Tidak bisa membaca version dari pubspec.yaml" >&2
  exit 1
}

SEMVER="${VERSION%%+*}"
TAG="v${SEMVER}"
TARGET_PKG="build/macos/ARA_Assessment_Setup_${TAG}.pkg"
REPO="diasutsman/ara_desktop"

echo "=========================================================="
echo " ARA Assessment macOS Build & Upload"
echo " Version : $VERSION (Tag: $TAG)"
echo " Output  : $TARGET_PKG"
echo "=========================================================="

# 1. Pastikan kredensial GitHub siap di DEPAN sebelum proses build yang lama
USE_GH_CLI=0
TOKEN=""
KEYCHAIN_SERVICE="ara_desktop_github_token"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  USE_GH_CLI=1
  echo "==> Menggunakan autentikasi GitHub CLI (gh)."
else
  TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [[ -z "$TOKEN" ]]; then
    TOKEN="$(security find-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)"
  fi

  if [[ -z "$TOKEN" ]]; then
    echo ""
    read -rsp "Masukkan GitHub Token di awal (input tersembunyi, disimpan aman di macOS Keychain): " TOKEN
    echo ""
    if [[ -n "$TOKEN" ]]; then
      security add-generic-password -U -a "$USER" -s "$KEYCHAIN_SERVICE" -w "$TOKEN" >/dev/null 2>&1 || true
      echo "==> Token berhasil disimpan aman di macOS Keychain."
    fi
  else
    echo "==> Token GitHub ditemukan di environment / macOS Keychain."
  fi

  if [[ -z "$TOKEN" ]]; then
    echo "ERROR: GitHub token kosong. Proses dibatalkan sebelum build." >&2
    exit 1
  fi
fi

# 2. Build .pkg Universal
chmod +x "$PROJECT_ROOT/scripts/build_macos.sh"
"$PROJECT_ROOT/scripts/build_macos.sh"

BUILT_PKG="build/macos/ARA_Assessment_${VERSION}.pkg"
if [[ ! -f "$BUILT_PKG" ]]; then
  BUILT_PKG="$(find build/macos -maxdepth 1 -name '*.pkg' | head -n 1 || true)"
fi

[[ -n "$BUILT_PKG" && -f "$BUILT_PKG" ]] || {
  echo "ERROR: File .pkg hasil build tidak ditemukan di build/macos/" >&2
  exit 1
}

cp -f "$BUILT_PKG" "$TARGET_PKG"
echo "==> File PKG siap diunggah: $TARGET_PKG"

# 3. Upload ke GitHub Release
if [[ "$USE_GH_CLI" -eq 1 ]]; then
  echo "==> Mengunggah menggunakan GitHub CLI (gh)..."
  if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release create "$TAG" --repo "$REPO" --title "ARA Assessment ${TAG}" --notes "ARA Assessment Desktop ${TAG} (${VERSION})"
  fi
  gh release upload "$TAG" "$TARGET_PKG" --repo "$REPO" --clobber
  echo "==> [SUCCESS] Terunggah ke: https://github.com/${REPO}/releases/download/${TAG}/$(basename "$TARGET_PKG")"
  exit 0
fi

echo "==> Mengunggah via GitHub REST API ke release $TAG..."
RELEASE_JSON="$(curl -sS -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/releases/tags/${TAG}")"

UPLOAD_URL="$(printf '%s' "$RELEASE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('upload_url','').split('{')[0])" 2>/dev/null || true)"

if [[ -z "$UPLOAD_URL" ]]; then
  CREATE_PAYLOAD="$(printf '{"tag_name":"%s","name":"ARA Assessment %s","body":"ARA Assessment Desktop %s (%s)","draft":false,"prerelease":false}' "$TAG" "$TAG" "$TAG" "$VERSION")"
  RELEASE_JSON="$(curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
    -d "$CREATE_PAYLOAD" "https://api.github.com/repos/${REPO}/releases")"
  UPLOAD_URL="$(printf '%s' "$RELEASE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('upload_url','').split('{')[0])")"
fi

[[ -n "$UPLOAD_URL" ]] || {
  echo "ERROR: Gagal mendapatkan upload_url untuk release $TAG" >&2
  exit 1
}

FILE_NAME="$(basename "$TARGET_PKG")"

# Jika asset dengan nama yang sama sudah ada di release, hapus dulu agar bisa di-overwrite (clobber)
EXISTING_ASSET_ID="$(printf '%s' "$RELEASE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(next((str(a['id']) for a in d.get('assets',[]) if a.get('name')=='$FILE_NAME'), ''))" 2>/dev/null || true)"
if [[ -n "$EXISTING_ASSET_ID" ]]; then
  curl -sS -X DELETE -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/releases/assets/${EXISTING_ASSET_ID}" >/dev/null || true
fi

curl -fL -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/octet-stream" \
  --data-binary "@${TARGET_PKG}" \
  "${UPLOAD_URL}?name=${FILE_NAME}" >/dev/null

echo "=========================================================="
echo " [SUCCESS] macOS PKG berhasil diunggah!"
echo " Download: https://github.com/${REPO}/releases/download/${TAG}/${FILE_NAME}"
echo "=========================================================="
