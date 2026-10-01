#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
PROJECT_DIR="${ROOT_DIR:h}"
BUILD_DIR="$ROOT_DIR/build"
OBJECT_DIR="$BUILD_DIR/objects"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
APP_DIR="$BUILD_DIR/Gauge for Codex.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
PLUGINS_DIR="$CONTENTS_DIR/PlugIns"
WIDGET_SOURCE_DIR="$PROJECT_DIR/widget"
WIDGET_DIR="$PLUGINS_DIR/GaugeForCodexWidget.appex"
WIDGET_CONTENTS_DIR="$WIDGET_DIR/Contents"
WIDGET_MACOS_DIR="$WIDGET_CONTENTS_DIR/MacOS"
WIDGET_RESOURCES_DIR="$WIDGET_CONTENTS_DIR/Resources"
ICON_MASTER="$BUILD_DIR/AppIcon-master.png"
ICON_TIFF="$BUILD_DIR/AppIcon.tiff"
ICON_TIFF_DIR="$BUILD_DIR/IconTIFFs"
ICON_SOURCE="$PROJECT_DIR/shared/CodexGaugeIcon.m"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_MAJOR="${SDK_VERSION%%.*}"
BUILD_WIDGET=0
if (( SDK_MAJOR >= 14 )); then
  BUILD_WIDGET=1
fi

rm -rf "$APP_DIR" "$OBJECT_DIR" "$ICON_TIFF_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$HELPERS_DIR" "$OBJECT_DIR" "$ICON_TIFF_DIR"
cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
for locale_dir in "$ROOT_DIR"/*.lproj; do
  cp -R "$locale_dir" "$RESOURCES_DIR/"
done

# Swift provides the WidgetCenter bridge while Objective-C keeps the menu-bar
# process compatible with macOS 12. Link with swiftc so the Swift runtime paths
# are embedded correctly for both Universal 2 slices.
if (( BUILD_WIDGET )); then
  mkdir -p "$WIDGET_MACOS_DIR" "$WIDGET_RESOURCES_DIR"
  cp "$WIDGET_SOURCE_DIR/Info.plist" "$WIDGET_CONTENTS_DIR/Info.plist"
  for locale_dir in "$WIDGET_SOURCE_DIR"/*.lproj; do
    cp -R "$locale_dir" "$WIDGET_RESOURCES_DIR/"
  done
  for arch in arm64 x86_64; do
    header_args=()
    if [[ "$arch" == "arm64" ]]; then
      header_args=(-emit-objc-header -emit-objc-header-path "$OBJECT_DIR/GaugeForCodex-Swift.h")
    fi
    xcrun swiftc \
      -parse-as-library -O \
      -target "$arch-apple-macosx12.0" \
      -module-name GaugeForCodex \
      -emit-object "${header_args[@]}" \
      "$ROOT_DIR/WidgetBridge.swift" \
      -o "$OBJECT_DIR/WidgetBridge-$arch.o"

    xcrun clang \
      -fobjc-arc -fmodules \
      -Wall -Wextra -Werror \
      -arch "$arch" -mmacosx-version-min=12.0 \
      -I "$OBJECT_DIR" \
      -c "$ROOT_DIR/main.m" \
      -o "$OBJECT_DIR/main-$arch.o"

    xcrun swiftc \
      -target "$arch-apple-macosx12.0" \
      "$OBJECT_DIR/main-$arch.o" "$OBJECT_DIR/WidgetBridge-$arch.o" \
      -framework Cocoa -framework WidgetKit \
      -o "$OBJECT_DIR/GaugeForCodex-$arch"

    xcrun swiftc \
      -parse-as-library -application-extension -O \
      -target "$arch-apple-macosx14.0" \
      -framework AppKit -framework SwiftUI -framework WidgetKit \
      "$WIDGET_SOURCE_DIR/GaugeForCodexWidget.swift" \
      -o "$OBJECT_DIR/GaugeForCodexWidget-$arch"
  done

  lipo -create "$OBJECT_DIR/GaugeForCodex-arm64" "$OBJECT_DIR/GaugeForCodex-x86_64" \
    -output "$MACOS_DIR/GaugeForCodex"
  lipo -create "$OBJECT_DIR/GaugeForCodexWidget-arm64" "$OBJECT_DIR/GaugeForCodexWidget-x86_64" \
    -output "$WIDGET_MACOS_DIR/GaugeForCodexWidget"
else
  echo "warning: macOS SDK $SDK_VERSION cannot build the macOS 14 WidgetKit extension; building the menu app only" >&2
  xcrun clang \
    -fobjc-arc -fno-modules -DQG_WIDGETKIT_BRIDGE=0 \
    -Wall -Wextra -Werror \
    -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 \
    -framework Cocoa \
    "$ROOT_DIR/main.m" \
    -o "$MACOS_DIR/GaugeForCodex"
fi

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
if (( BUILD_WIDGET )); then
  cp "$RESOURCES_DIR/AppIcon.icns" "$WIDGET_RESOURCES_DIR/AppIcon.icns"
fi

plutil -lint "$CONTENTS_DIR/Info.plist"
if (( BUILD_WIDGET )); then
  plutil -lint "$WIDGET_CONTENTS_DIR/Info.plist"
fi
for strings_file in "$RESOURCES_DIR"/*.lproj/Localizable.strings; do
  plutil -lint "$strings_file"
done
if (( BUILD_WIDGET )); then
  for strings_file in "$WIDGET_RESOURCES_DIR"/*.lproj/Localizable.strings; do
    plutil -lint "$strings_file"
  done
fi
"$MACOS_DIR/GaugeForCodex" --self-test

# Sign nested code first, then seal the host. Public artifacts remain ad-hoc
# signed until a Developer ID/notarization identity is configured.
codesign --force --sign - "$HELPERS_DIR/GaugeForCodexUpdater"
if (( BUILD_WIDGET )); then
  codesign --force --sign - "$WIDGET_DIR"
fi
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
lipo "$MACOS_DIR/GaugeForCodex" -verify_arch arm64 x86_64
if (( BUILD_WIDGET )); then
  lipo "$WIDGET_MACOS_DIR/GaugeForCodexWidget" -verify_arch arm64 x86_64
fi
lipo "$HELPERS_DIR/GaugeForCodexUpdater" -verify_arch arm64 x86_64
echo "Built: $APP_DIR"
