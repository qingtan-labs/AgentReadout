#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/Gauge for Codex Launcher.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_MASTER="$BUILD_DIR/AppIcon-master.png"
ICON_TIFF="$BUILD_DIR/AppIcon.tiff"
ICON_TIFF_DIR="$BUILD_DIR/IconTIFFs"
ICON_SOURCE="$ROOT_DIR/../assets/app-icon.png"

rm -rf "$APP_DIR" "$ICON_TIFF_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICON_TIFF_DIR"
cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

xcrun clang \
  -fobjc-arc \
  -fno-modules \
  -Wall -Wextra -Werror \
  -arch arm64 -arch x86_64 \
  -mmacosx-version-min=12.0 \
  -framework Cocoa \
  "$ROOT_DIR/main.m" \
  -o "$MACOS_DIR/GaugeForCodexLauncher"

cp "$ICON_SOURCE" "$ICON_MASTER"
for size in 16 32 48 128 256 512 1024; do
  sips -z "$size" "$size" "$ICON_MASTER" --out "$ICON_TIFF_DIR/icon-${size}.png" >/dev/null
  sips -s format tiff "$ICON_TIFF_DIR/icon-${size}.png" --out "$ICON_TIFF_DIR/icon-${size}.tiff" >/dev/null
done
tiffutil -cat "$ICON_TIFF_DIR"/*.tiff -out "$ICON_TIFF" >/dev/null 2>&1
tiff2icns "$ICON_TIFF" "$RESOURCES_DIR/AppIcon.icns"

plutil -lint "$CONTENTS_DIR/Info.plist"
"$MACOS_DIR/GaugeForCodexLauncher" --self-test
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
lipo "$MACOS_DIR/GaugeForCodexLauncher" -verify_arch arm64
lipo "$MACOS_DIR/GaugeForCodexLauncher" -verify_arch x86_64
echo "Built: $APP_DIR"
