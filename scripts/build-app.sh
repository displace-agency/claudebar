#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="RelayBar"
VERSION="${1:-1.0.0}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$ ]]; then
    echo "Invalid version: use a version such as 1.0.0." >&2
    exit 1
fi
BUILD_ROOT="build"
APP_DIR="${BUILD_ROOT}/${APP_NAME}.app"

echo "→ Building universal binary (arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64

BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/${APP_NAME}"
if [ ! -f "${BIN_PATH}" ]; then
    # Older swift-pm falls back here
    BIN_PATH=".build/apple/Products/Release/${APP_NAME}"
fi
if [ ! -f "${BIN_PATH}" ]; then
    echo "Could not locate built binary." >&2
    exit 1
fi

echo "→ Assembling ${APP_DIR}…"
if [ -e "${APP_DIR}" ]; then
    BACKUP_DIR="${APP_DIR}.backup-$(date +%Y%m%d-%H%M%S)"
    mv "${APP_DIR}" "${BACKUP_DIR}"
    printf 'Previous app bundle preserved at %s\n' "${BACKUP_DIR}" > "${BACKUP_DIR}.manifest.txt"
fi
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"

if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${APP_DIR}/Contents/Info.plist" 2>/dev/null || true
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP_DIR}/Contents/Info.plist"

SIGNING_IDENTITY="${CODESIGN_IDENTITY:--}"
echo "→ Signing with ${SIGNING_IDENTITY}…"
codesign --force --deep --sign "${SIGNING_IDENTITY}" "${APP_DIR}"
codesign --verify --deep --strict "${APP_DIR}"

echo "✓ Built ${APP_DIR}"
