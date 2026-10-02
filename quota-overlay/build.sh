#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
PROJECT_DIR="${ROOT_DIR:h}"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/Gauge for Codex.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
ICON_MASTER="$BUILD_DIR/AppIcon-master.png"
ICON_TIFF="$BUILD_DIR/AppIcon.tiff"
ICON_TIFF_DIR="$BUILD_DIR/IconTIFFs"
ICON_SOURCE="$PROJECT_DIR/shared/CodexGaugeIcon.m"
WIDGET_SOURCE_DIR="$ROOT_DIR/widget"
WIDGET_APP_DIR="$CONTENTS_DIR/PlugIns/GaugeForCodexWidget.appex"

rm -rf "$APP_DIR" "$ICON_TIFF_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$HELPERS_DIR" "$ICON_TIFF_DIR"
cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
for locale_dir in "$ROOT_DIR"/*.lproj; do
  cp -R "$locale_dir" "$RESOURCES_DIR/"
done

xcrun clang \
  -fobjc-arc -fno-modules \
  -Wall -Wextra -Werror \
  -arch arm64 -arch x86_64 \
  -mmacosx-version-min=12.0 \
  -framework Cocoa -framework CoreGraphics -framework QuartzCore \
  "$ROOT_DIR/main.m" "$ROOT_DIR/QGWidgetServer.m" \
  -o "$MACOS_DIR/GaugeForCodex"

xcrun clang \
  -fobjc-arc -fno-modules \
  -Wall -Wextra -Werror \
  -arch arm64 -arch x86_64 \
  -mmacosx-version-min=12.0 \
  -framework Cocoa \
  "$ROOT_DIR/updater.m" \
  -o "$HELPERS_DIR/GaugeForCodexUpdater"

xcrun clang \
  -fobjc-arc -fno-modules \
  -Wall -Wextra -Werror \
  -mmacosx-version-min=12.0 \
  -framework Cocoa \
  "$ICON_SOURCE" \
  -o "$BUILD_DIR/GenerateGaugeForCodexIcon"
"$BUILD_DIR/GenerateGaugeForCodexIcon" "$ICON_MASTER"
for size in 16 32 48 128 256 512 1024; do
  sips -z "$size" "$size" "$ICON_MASTER" --out "$ICON_TIFF_DIR/icon-${size}.png" >/dev/null
  sips -s format tiff "$ICON_TIFF_DIR/icon-${size}.png" --out "$ICON_TIFF_DIR/icon-${size}.tiff" >/dev/null
done
tiffutil -cat "$ICON_TIFF_DIR"/*.tiff -out "$ICON_TIFF" >/dev/null 2>&1
tiff2icns "$ICON_TIFF" "$RESOURCES_DIR/AppIcon.icns"

plutil -lint "$CONTENTS_DIR/Info.plist"
for strings_file in "$RESOURCES_DIR"/*.lproj/Localizable.strings; do
  plutil -lint "$strings_file"
done
"$MACOS_DIR/GaugeForCodex" --self-test

# WidgetKit's native desktop rendering starts on macOS 14. The local fallback
# build remains usable with older Command Line Tools; releases require Xcode.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_MAJOR="${SDK_VERSION%%.*}"
if (( SDK_MAJOR >= 14 )); then
  WIDGET_SDK="$(xcrun --sdk macosx --show-sdk-path)"
  mkdir -p "$WIDGET_APP_DIR/Contents/MacOS"
  cp "$WIDGET_SOURCE_DIR/Info.plist" "$WIDGET_APP_DIR/Contents/Info.plist"
  for arch in arm64 x86_64; do
    xcrun swiftc \
      -O -parse-as-library -application-extension \
      -target "${arch}-apple-macos14.0" \
      -sdk "$WIDGET_SDK" \
      -module-name GaugeForCodexWidget \
      "$WIDGET_SOURCE_DIR/GaugeWidget.swift" \
      -o "$BUILD_DIR/GaugeForCodexWidget-$arch"
  done
  lipo -create "$BUILD_DIR/GaugeForCodexWidget-arm64" "$BUILD_DIR/GaugeForCodexWidget-x86_64" \
    -output "$WIDGET_APP_DIR/Contents/MacOS/GaugeForCodexWidget"
  plutil -lint "$WIDGET_APP_DIR/Contents/Info.plist"
  codesign --force --sign - --entitlements "$WIDGET_SOURCE_DIR/Widget.entitlements" "$WIDGET_APP_DIR"
  lipo "$WIDGET_APP_DIR/Contents/MacOS/GaugeForCodexWidget" -verify_arch arm64 x86_64
else
  echo "Native WidgetKit extension skipped: macOS 14 SDK or newer is required."
fi

codesign --force --sign - "$HELPERS_DIR/GaugeForCodexUpdater"
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
lipo "$MACOS_DIR/GaugeForCodex" -verify_arch arm64 x86_64
lipo "$HELPERS_DIR/GaugeForCodexUpdater" -verify_arch arm64 x86_64
echo "Built: $APP_DIR"
