#!/bin/zsh
set -euo pipefail
REGRESSION_ROOT="${0:A:h}"
REGRESSION_DIR="$(mktemp -d "${TMPDIR:-/private/tmp/}GaugeRegression.XXXXXX")"
trap 'rm -rf "$REGRESSION_DIR"' EXIT

xcrun clang -fobjc-arc -fno-modules -Wall -Wextra -Werror -framework Foundation \
  "$REGRESSION_ROOT/InsightsRegressionTests.m" -o "$REGRESSION_DIR/InsightsRegressionTests"
"$REGRESSION_DIR/InsightsRegressionTests"
xcrun clang -fobjc-arc -fno-modules -Wall -Wextra -Werror -framework Foundation \
  "$REGRESSION_ROOT/DailyUsageRegressionTests.m" -o "$REGRESSION_DIR/DailyUsageRegressionTests"
"$REGRESSION_DIR/DailyUsageRegressionTests"

xcrun swiftc -D WIDGET_PREVIEW -module-cache-path "$REGRESSION_DIR/ModuleCache" \
  "$REGRESSION_ROOT/widget/GaugeWidget.swift" "$REGRESSION_ROOT/widget/WidgetRegressionTests.swift" \
  -o "$REGRESSION_DIR/WidgetRegressionTests"
"$REGRESSION_DIR/WidgetRegressionTests"
xcrun clang -fobjc-arc -fno-modules -Wall -Wextra -Werror -framework Cocoa \
  "$REGRESSION_ROOT/UpdaterRegressionTests.m" -o "$REGRESSION_DIR/UpdaterRegressionTests"
"$REGRESSION_DIR/UpdaterRegressionTests"

# Validate release metadata against an isolated fixture, never the installed app.
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
  "$REGRESSION_ROOT/GenerateUpdateManifest.m" -o "$REGRESSION_DIR/GenerateUpdateManifest"
mkdir -p "$REGRESSION_DIR/Gauge.app/Contents"
cp "$REGRESSION_ROOT/Info.plist" "$REGRESSION_DIR/Gauge.app/Contents/Info.plist"
ditto -c -k --keepParent "$REGRESSION_DIR/Gauge.app" "$REGRESSION_DIR/Gauge-Universal.zip"
"$REGRESSION_DIR/GenerateUpdateManifest" "$REGRESSION_DIR/Gauge.app" "$REGRESSION_DIR/Gauge-Universal.zip"
REGRESSION_MANIFEST="$REGRESSION_DIR/update.json"
[[ "$(plutil -extract build raw -o - "$REGRESSION_MANIFEST")" == "$(plutil -extract CFBundleVersion raw -o - "$REGRESSION_ROOT/Info.plist")" ]]
[[ "$(plutil -extract version raw -o - "$REGRESSION_MANIFEST")" == "$(plutil -extract CFBundleShortVersionString raw -o - "$REGRESSION_ROOT/Info.plist")" ]]
[[ "$(plutil -extract bundleIdentifier raw -o - "$REGRESSION_MANIFEST")" == "com.qingtanlabs.gaugeforcodex" ]]
[[ "$(plutil -extract archive raw -o - "$REGRESSION_MANIFEST")" == "Gauge-Universal.zip" ]]
REGRESSION_HASH="$(shasum -a 256 "$REGRESSION_DIR/Gauge-Universal.zip")"
[[ "$(plutil -extract sha256 raw -o - "$REGRESSION_MANIFEST")" == "${REGRESSION_HASH%% *}" ]]
echo "PASS generated update manifest: version, build, identity, archive, SHA256"
