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

# Регистрируем в LaunchServices и Spotlight, иначе Finder/Spotlight не увидит по имени.
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "$LSREG" ]]; then
    "$LSREG" -f "$DEST" >/dev/null 2>&1 || true
fi
mdimport "$DEST" >/dev/null 2>&1 || true

echo '==> [5/6] Wiring cmux CLI on PATH (so `cmux context` works everywhere)'
# Why: the stock cmux.app's bin/ dir often appears earlier in PATH and ships
# without `cmux context`. We install a thin shim to TeamCmux's binary at the
# *first* writable PATH entry, and — if the stock cmux.app exists — also
# replace its CLI with the same shim (backing the original up). Result:
# any shell, any agent, any session resolves `cmux` to the TeamCmux binary.
TEAMCMUX_BIN="${DEST}/Contents/Resources/bin/cmux"
if [[ ! -x "$TEAMCMUX_BIN" ]]; then
    echo "warning: TeamCmux CLI not found at $TEAMCMUX_BIN — context commands will not be available from shell" >&2
else
    SHIM_BODY=$(cat <<EOF
#!/usr/bin/env bash
# cmux → TeamCmux CLI shim (managed by scripts/install-teamcmux.sh).
exec "$TEAMCMUX_BIN" "\$@"
EOF
)
    install_shim() {
        local target="$1"
        local needs_sudo="$2"
        if [[ "$needs_sudo" == "1" ]]; then
            echo "$SHIM_BODY" | sudo tee "$target" >/dev/null && sudo chmod +x "$target"
        else
            mkdir -p "$(dirname "$target")"
            echo "$SHIM_BODY" > "$target" && chmod +x "$target"
        fi
    }

    # 1. Drop a shim into the user's ~/.local/bin (early on PATH for most setups).
    install_shim "$HOME/.local/bin/cmux" "0" || true
    echo "  shim → $HOME/.local/bin/cmux"

    # 2. Detect cmux instances earlier on PATH and shadow them.
    #    `set -e` plus a per-iteration `continue` inside `for ... in $PATH` was
    #    swallowing the body silently in some shells — split via `tr` instead.
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        candidate="$dir/cmux"
        # Skip TeamCmux's own bin dir and the shim we just wrote.
        [[ "$candidate" == "$TEAMCMUX_BIN" ]] && continue
        [[ "$candidate" == "$HOME/.local/bin/cmux" ]] && continue
        [[ -f "$candidate" ]] || continue
        # Don't touch our own shims (idempotent re-runs).
        if grep -q "TeamCmux CLI shim" "$candidate" 2>/dev/null; then continue; fi

        backup="${candidate}.pre-teamcmux"
        if [[ ! -e "$backup" ]]; then
            if [[ -w "$candidate" ]]; then
                cp -p "$candidate" "$backup"
            else
                sudo cp -p "$candidate" "$backup" 2>/dev/null || true
            fi
        fi
        if [[ -w "$candidate" ]]; then
            install_shim "$candidate" "0"
        else
            install_shim "$candidate" "1" || { echo "  skip $candidate (no permission)" >&2; continue; }
        fi
        echo "  shadowed: $candidate (backup: $backup)"
    done < <(printf '%s' "$PATH" | tr ':' '\n')

    # 3. Hash refresh hint.
    hash -r 2>/dev/null || true
fi

echo "==> [6/6] Launching"
open "$DEST"

echo ""
echo "Installed: $DEST"
echo "Bundle id: $BUNDLE_ID"
echo "CLI shim:  uses TeamCmux for every cmux invocation"
echo "Ищи в Launchpad/Spotlight как ${APP_NAME}."
echo ""
echo 'Verify: open a new terminal and run  `cmux context show`'
