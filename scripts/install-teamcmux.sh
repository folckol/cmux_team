#!/usr/bin/env bash
# Сборка и установка TeamCmux.app в /Applications из исходников.
# Использование: ./scripts/install-teamcmux.sh
#
# Что делает:
#   1. Инициализирует сабмодули и собирает GhosttyKit (scripts/setup.sh).
#   2. Собирает Release с именем TeamCmux и собственным bundle id (не конфликтует с обычным cmux).
#   3. Копирует .app в /Applications, снимает карантин и запускает.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

APP_NAME="TeamCmux"
BUNDLE_ID="com.cmuxterm.teamcmux"
DERIVED="/tmp/cmux-team-build"
DEST="/Applications/${APP_NAME}.app"

echo "==> [1/4] Setup (submodules + GhosttyKit)"
"${SCRIPT_DIR}/setup.sh"

echo "==> [2/4] Building Release as ${APP_NAME}"
xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  PRODUCT_NAME="$APP_NAME" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  INFOPLIST_KEY_CFBundleName="$APP_NAME" \
  INFOPLIST_KEY_CFBundleDisplayName="$APP_NAME" \
  build

APP_PATH="${DERIVED}/Build/Products/Release/${APP_NAME}.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "error: built app not found at $APP_PATH" >&2
    exit 1
fi

echo "==> [3/4] Installing to ${DEST}"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.3
rm -rf "$DEST"
cp -R "$APP_PATH" "$DEST"
xattr -dr com.apple.quarantine "$DEST" || true

echo "==> [4/4] Launching"
open "$DEST"

echo ""
echo "Installed: $DEST"
echo "Bundle id: $BUNDLE_ID"
echo "Запускай через Launchpad / Spotlight как ${APP_NAME}."
