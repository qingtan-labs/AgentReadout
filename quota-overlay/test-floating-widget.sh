#!/bin/zsh
set -euo pipefail
WIDGET_TEST_ROOT="${0:A:h}"
WIDGET_TEST_APP="$WIDGET_TEST_ROOT/build/FloatingWidgetPreview.app"
mkdir -p "$WIDGET_TEST_APP/Contents/MacOS" "$WIDGET_TEST_APP/Contents/Resources"
xcrun clang -fobjc-arc -fno-modules -Wall -Wextra -Werror -mmacosx-version-min=12.0 \
  -framework Cocoa -framework CoreGraphics -framework ImageIO -framework QuartzCore -framework Security -framework UserNotifications \
  "$WIDGET_TEST_ROOT/FloatingWidgetPreview.m" "$WIDGET_TEST_ROOT/QGWidgetServer.m" "$WIDGET_TEST_ROOT/QGClaudeQuota.m" \
  -o "$WIDGET_TEST_APP/Contents/MacOS/FloatingWidgetPreview"
for widget_test_locale in "$WIDGET_TEST_ROOT"/*.lproj; do
  cp -R "$widget_test_locale" "$WIDGET_TEST_APP/Contents/Resources/"
done
"$WIDGET_TEST_APP/Contents/MacOS/FloatingWidgetPreview" "$WIDGET_TEST_ROOT/build/FloatingWidgetPreviews"
