#!/bin/zsh
# Builds "Codex Model Bar.app", signs it, installs it to ~/Applications and relaunches it.
#
# Usage: scripts/build-app.sh [--no-install]
#
# A stable Apple Development identity keeps Accessibility permission across
# rebuilds. Other machines can use an ad-hoc signature for a first install.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

APP_NAME="Codex Model Bar"
BUNDLE_ID="com.ethansk.codex-model-bar"
VERSION="$(cat VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || true)"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
if (( BUILD_NUMBER < 1 )); then BUILD_NUMBER=1; fi
OUT="$ROOT/build"
APP="$OUT/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
ARCH="${CODEX_MODEL_BAR_ARCH:-$(uname -m)}"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
SIGN_ID="${CODEX_MODEL_BAR_SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q 'Apple Development'; then
    SIGN_ID="Apple Development"
  else
    SIGN_ID="-"
  fi
fi

echo "==> Building release binary"
swift build -c release --arch "$ARCH"
BIN_DIR="$(swift build --show-bin-path -c release --arch "$ARCH")"

echo "==> Rendering icon"
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$OUT/AppIcon.icns"

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CodexModelBar" "$APP/Contents/MacOS/CodexModelBar"
cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" -e "s/__BUNDLE_ID__/$BUNDLE_ID/" \
  Resources/Info.plist > "$APP/Contents/Info.plist"

echo "==> Signing with \"$SIGN_ID\""
codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" "$APP"
codesign --verify --strict "$APP"

if [[ "${1:-}" == "--no-install" ]]; then
  echo "Built $APP (not installed)"
  exit 0
fi

echo "==> Installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
# Quit the running copy first so the binary can be replaced cleanly.
pkill -x CodexModelBar 2>/dev/null && sleep 0.5 || true
# Keep one rollback copy of the previous install.
if [[ -d "$INSTALL_DIR/$APP_NAME.app" ]]; then
  rm -rf "$OUT/previous.app"
  mv "$INSTALL_DIR/$APP_NAME.app" "$OUT/previous.app"
fi
ditto "$APP" "$INSTALL_DIR/$APP_NAME.app"
open -g "$INSTALL_DIR/$APP_NAME.app"
echo "Installed and launched $INSTALL_DIR/$APP_NAME.app ($VERSION build $BUILD_NUMBER)"
