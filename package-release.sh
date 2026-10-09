#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
VERSION="${1:-2.0.1}"
RELEASE_DIR="$ROOT_DIR/release"
STAGING_DIR="$(mktemp -d)"
APP_SOURCE="$ROOT_DIR/quota-overlay/build/Gauge for Codex.app"
DMG_PATH="$RELEASE_DIR/AgentReadout-$VERSION-Universal.dmg"
ZIP_PATH="$RELEASE_DIR/AgentReadout-$VERSION-Universal.zip"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

"$ROOT_DIR/quota-overlay/build.sh"

WIDGET_BINARY="$APP_SOURCE/Contents/PlugIns/GaugeForCodexWidget.appex/Contents/MacOS/GaugeForCodexWidget"
if [[ ! -x "$WIDGET_BINARY" ]]; then
  echo "Release requires the native WidgetKit extension. Build with full Xcode and XcodeGen." >&2
  exit 1
fi

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SOURCE/Contents/Info.plist")"
if [[ "$BUILT_VERSION" != "$VERSION" ]]; then
  echo "Version mismatch: requested $VERSION but app declares $BUILT_VERSION" >&2
  exit 1
fi

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

ditto "$APP_SOURCE" "$STAGING_DIR/AgentReadout.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname "AgentReadout" -srcfolder "$STAGING_DIR" \
  -ov -format UDZO "$DMG_PATH" >/dev/null
ditto -c -k --sequesterRsrc --keepParent "$STAGING_DIR/AgentReadout.app" "$ZIP_PATH"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
  "$ROOT_DIR/quota-overlay/GenerateUpdateManifest.m" -o "$STAGING_DIR/GenerateUpdateManifest"
"$STAGING_DIR/GenerateUpdateManifest" "$APP_SOURCE" "$ZIP_PATH"

(
  cd "$RELEASE_DIR"
  shasum -a 256 "${DMG_PATH:t}" "${ZIP_PATH:t}" update.json > SHA256SUMS
)

echo "Release artifacts: $RELEASE_DIR"
