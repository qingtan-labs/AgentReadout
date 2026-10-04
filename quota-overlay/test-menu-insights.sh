#!/bin/zsh
set -euo pipefail
INSIGHTS_ROOT="${0:A:h}"
INSIGHTS_APP="$INSIGHTS_ROOT/build/MenuInsightsPreview.app"
mkdir -p "$INSIGHTS_APP/Contents/MacOS" "$INSIGHTS_APP/Contents/Resources"
xcrun clang -fobjc-arc -fno-modules -Wall -Wextra -Werror -mmacosx-version-min=12.0 \
  -framework Cocoa -framework CoreGraphics -framework ImageIO -framework QuartzCore -framework Security -framework UserNotifications \
  "$INSIGHTS_ROOT/MenuPreview.m" "$INSIGHTS_ROOT/QGWidgetServer.m" "$INSIGHTS_ROOT/QGClaudeQuota.m" \
  -o "$INSIGHTS_APP/Contents/MacOS/MenuPreview"
for insights_locale in "$INSIGHTS_ROOT"/*.lproj; do
  cp -R "$insights_locale" "$INSIGHTS_APP/Contents/Resources/"
done
"$INSIGHTS_APP/Contents/MacOS/MenuPreview" "$INSIGHTS_ROOT/build/MenuInsightsPreviews" -AppleLanguages '(zh-Hans)'
