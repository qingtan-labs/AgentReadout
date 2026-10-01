#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
VERSION="${1:-1.0.1}"
RELEASE_DIR="$ROOT_DIR/release"
STAGING_DIR="$(mktemp -d)"
APP_SOURCE="$ROOT_DIR/quota-overlay/build/Gauge for Codex.app"
DMG_PATH="$RELEASE_DIR/Gauge-for-Codex-$VERSION-Universal.dmg"
ZIP_PATH="$RELEASE_DIR/Gauge-for-Codex-$VERSION-Universal.zip"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
"$ROOT_DIR/quota-overlay/build.sh"

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SOURCE/Contents/Info.plist")"
if [[ "$BUILT_VERSION" != "$VERSION" ]]; then
  echo "Version mismatch: requested $VERSION but app declares $BUILT_VERSION" >&2
  exit 1
fi
if [[ ! -d "$APP_SOURCE/Contents/PlugIns/GaugeForCodexWidget.appex" ]]; then
  echo "Release builds require Xcode 15 or later and the embedded WidgetKit extension" >&2
  exit 1
fi

ditto "$APP_SOURCE" "$STAGING_DIR/Gauge for Codex.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname "Gauge for Codex" -srcfolder "$STAGING_DIR" \
  -ov -format UDZO "$DMG_PATH" >/dev/null
ditto -c -k --sequesterRsrc --keepParent "$APP_SOURCE" "$ZIP_PATH"

(
  cd "$RELEASE_DIR"
  shasum -a 256 "${DMG_PATH:t}" "${ZIP_PATH:t}" > SHA256SUMS
)

echo "Release artifacts: $RELEASE_DIR"
