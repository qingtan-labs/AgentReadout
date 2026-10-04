#!/bin/zsh
set -euo pipefail
PREVIEW_ROOT="${0:A:h}"
PREVIEW_BUILD="$PREVIEW_ROOT/build/NativeWidgetStyles"
mkdir -p "$PREVIEW_BUILD"
xcrun swiftc -D WIDGET_PREVIEW -module-cache-path "$PREVIEW_BUILD/ModuleCache" \
  "$PREVIEW_ROOT/widget/GaugeWidget.swift" "$PREVIEW_ROOT/widget/WidgetPreview.swift" \
  -o "$PREVIEW_BUILD/WidgetPreview"
"$PREVIEW_BUILD/WidgetPreview" "$PREVIEW_BUILD/Previews"
