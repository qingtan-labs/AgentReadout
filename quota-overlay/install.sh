#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
APP_TARGET="$HOME/Applications/Gauge for Codex.app"
AGENT_TARGET="$HOME/Library/LaunchAgents/com.qingtanlabs.gaugeforcodex.plist"
LEGACY_AGENT_TARGET="$HOME/Library/LaunchAgents/com.local.codexgauge.plist"
GUI_DOMAIN="gui/$(id -u)"
AGENT_LABEL="com.qingtanlabs.gaugeforcodex"
LEGACY_AGENT_LABEL="com.local.codexgauge"

"$ROOT_DIR/build.sh"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
ditto "$ROOT_DIR/build/Gauge for Codex.app" "$APP_TARGET"
cp "$ROOT_DIR/com.qingtanlabs.gaugeforcodex.plist" "$AGENT_TARGET"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $APP_TARGET/Contents/MacOS/GaugeForCodex" "$AGENT_TARGET"

# Disable the pre-release CodexGauge login item without deleting it, so the
# migration is reversible and the two menu-bar processes cannot race.
launchctl bootout "$GUI_DOMAIN/$LEGACY_AGENT_LABEL" 2>/dev/null || true
if [[ -f "$LEGACY_AGENT_TARGET" && ! -e "$LEGACY_AGENT_TARGET.disabled" ]]; then
  mv "$LEGACY_AGENT_TARGET" "$LEGACY_AGENT_TARGET.disabled"
fi

launchctl bootout "$GUI_DOMAIN/$AGENT_LABEL" 2>/dev/null || true
if ! launchctl bootstrap "$GUI_DOMAIN" "$AGENT_TARGET"; then
  sleep 1
  launchctl bootstrap "$GUI_DOMAIN" "$AGENT_TARGET"
fi
launchctl kickstart -k "$GUI_DOMAIN/$AGENT_LABEL"
echo "Installed: $APP_TARGET"
