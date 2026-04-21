#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ClaudeBar"
VERSION="${1:-0.1.0}"
APP_DIR="build/${APP_NAME}.app"
DMG_PATH="build/${APP_NAME}-${VERSION}.dmg"

if [ ! -d "${APP_DIR}" ]; then
    echo "Missing ${APP_DIR}. Run scripts/build-app.sh first." >&2
    exit 1
fi

STAGE="build/dmg-stage"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"
cp -R "${APP_DIR}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"

rm -f "${DMG_PATH}"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGE}" \
    -ov -format UDZO \
    "${DMG_PATH}"

rm -rf "${STAGE}"
echo "✓ DMG at ${DMG_PATH}"
