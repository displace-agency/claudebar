#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="RelayBar"
VERSION="${1:-1.0.0}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$ ]]; then
    echo "Invalid version: use a version such as 1.0.0." >&2
    exit 1
fi
APP_DIR="build/${APP_NAME}.app"
DMG_PATH="build/${APP_NAME}-${VERSION}.dmg"

if [ ! -d "${APP_DIR}" ]; then
    echo "Missing ${APP_DIR}. Run scripts/build-app.sh first." >&2
    exit 1
fi

STAGE="$(mktemp -d build/dmg-stage.XXXXXX)"
cp -R "${APP_DIR}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"

if [ -e "${DMG_PATH}" ]; then
    echo "Refusing to overwrite ${DMG_PATH}; choose a new version." >&2
    exit 1
fi
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGE}" \
    -ov -format UDZO \
    "${DMG_PATH}"

rm -rf "${STAGE}"
echo "✓ DMG at ${DMG_PATH}"
