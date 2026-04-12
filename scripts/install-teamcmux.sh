#!/usr/bin/env bash
# Сборка и установка TeamCmux.app в /Applications из исходников.
# Использование: ./scripts/install-teamcmux.sh
#
# Что делает:
#   1. Инициализирует сабмодули и собирает GhosttyKit (scripts/setup.sh).
#   2. Собирает обычный Release cmux.app в изолированный DerivedData.
#   3. Копирует сборку в /Applications/TeamCmux.app, патчит Info.plist
#      (CFBundleName / DisplayName / Identifier), снимает карантин и запускает.
#
# Отдельный bundle id (com.cmuxterm.teamcmux) важен: без него приложение
# делит сокет/настройки/Sparkle-канал с обычным cmux и ломает его.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

APP_NAME="TeamCmux"
BUNDLE_ID="com.cmuxterm.teamcmux"
DERIVED="/tmp/cmux-team-build"
DEST="/Applications/${APP_NAME}.app"

echo "==> [1/5] Setup (submodules + GhosttyKit)"
"${SCRIPT_DIR}/setup.sh"

echo "==> [2/5] Building Release cmux.app"
xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  build

SRC_APP="${DERIVED}/Build/Products/Release/cmux.app"
if [[ ! -d "$SRC_APP" ]]; then
    echo "error: built app not found at $SRC_APP" >&2
    exit 1
fi

echo "==> [3/5] Installing to ${DEST}"
pkill -x "$APP_NAME" 2>/dev/null || true
pkill -x cmux 2>/dev/null || true
sleep 0.3
rm -rf "$DEST"
cp -R "$SRC_APP" "$DEST"

echo "==> [4/5] Rebranding bundle (name + bundle id)"
PLIST="${DEST}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_NAME}" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleName string ${APP_NAME}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${APP_NAME}" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ${APP_NAME}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$PLIST"

# Убираем подпись (после правки Info.plist она становится невалидной) и ставим ad-hoc.
codesign --remove-signature "$DEST" 2>/dev/null || true
codesign --force --deep --sign - "$DEST" 2>/dev/null || true

xattr -dr com.apple.quarantine "$DEST" || true

echo "==> [5/5] Launching"
open "$DEST"

echo ""
echo "Installed: $DEST"
echo "Bundle id: $BUNDLE_ID"
echo "Ищи в Launchpad/Spotlight как ${APP_NAME}."
