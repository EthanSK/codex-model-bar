#!/bin/zsh
# Builds "Codex Model Bar.app", signs it, installs it to ~/Applications and relaunches it.
#
# Usage: scripts/build-app.sh [--no-install]
#
# Keep the release signing family when available so local installs do not break
# an existing Accessibility grant. Other machines can use development or ad-hoc signing.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

APP_NAME="Codex Model Bar"
BUNDLE_ID="com.ethansk.codex-model-bar"
VERSION="$(cat VERSION)"
BUILD_NUMBER="$(cat BUILD_NUMBER)"
[[ "$BUILD_NUMBER" == <-> && "$BUILD_NUMBER" -gt 0 ]] || exit 65
OUT="${CODEX_MODEL_BAR_BUILD_ROOT:-$ROOT}/build.noindex"
SCRATCH="${CODEX_MODEL_BAR_BUILD_ROOT:-$ROOT}/.build.noindex"
APP="$OUT/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
ARCH="${CODEX_MODEL_BAR_ARCH:-$(uname -m)}"
case "$ARCH" in
  universal|arm64|x86_64) ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
SIGN_ID="${CODEX_MODEL_BAR_SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q 'Developer ID Application:'; then
    SIGN_ID="Developer ID Application:" # Public releases use this signing family; Apple Development would no longer match their Accessibility grant.
  elif security find-identity -v -p codesigning 2>/dev/null | grep -q 'Apple Development'; then
    SIGN_ID="Apple Development"
  else
    SIGN_ID="-"
  fi
fi

BUILD_FLAGS=(--arch "$ARCH")
if [[ "$ARCH" == universal ]]; then BUILD_FLAGS=(--arch arm64 --arch x86_64); fi
echo "==> Building release binary"
swift build --jobs 2 --scratch-path "$SCRATCH" -c release "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build --jobs 2 --scratch-path "$SCRATCH" --show-bin-path -c release "${BUILD_FLAGS[@]}")"

echo "==> Rendering icon"
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$OUT/AppIcon.icns"

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$BIN_DIR/CodexModelBar" "$APP/Contents/MacOS/CodexModelBar"
cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE LICENSING.md "$APP/Contents/Resources/"
cp Resources/setup-claude.sh "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" -e "s/__BUNDLE_ID__/$BUNDLE_ID/" \
  Resources/Info.plist > "$APP/Contents/Info.plist"

echo "==> Signing with \"$SIGN_ID\""
SIGN_FLAGS=(--timestamp=none)
if [[ "$SIGN_ID" != "-" ]]; then SIGN_FLAGS+=(--options runtime); fi
if [[ "$SIGN_ID" == "Developer ID Application:"* ]]; then SIGN_FLAGS=(--options runtime --timestamp); fi
for component in "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
  "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
  "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
  "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
  "$APP/Contents/Frameworks/Sparkle.framework" "$APP"; do
  codesign --force "${SIGN_FLAGS[@]}" --sign "$SIGN_ID" "$component"
done
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/CodexModelBar" --check-packaged-launch
# The release signer verifies this archive's hash against its exact source commit.
ditto -c -k --keepParent "$APP" "$OUT/CodexModelBar-prebuilt.zip"
python3 scripts/build-receipt.py "$OUT/CodexModelBar-prebuilt.zip"

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
