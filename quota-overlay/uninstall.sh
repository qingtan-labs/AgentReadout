#!/bin/zsh
set -euo pipefail

APP_TARGET="$HOME/Applications/Gauge for Codex.app"
AGENT_TARGET="$HOME/Library/LaunchAgents/com.qingtanlabs.gaugeforcodex.plist"
AGENT_LABEL="com.qingtanlabs.gaugeforcodex"
GUI_DOMAIN="gui/$(id -u)"
TRASH_DIR="$HOME/.Trash"
STAMP="$(date +%Y%m%d-%H%M%S)"

launchctl bootout "$GUI_DOMAIN/$AGENT_LABEL" 2>/dev/null || true
pkill -x GaugeForCodex 2>/dev/null || true
mkdir -p "$TRASH_DIR"

if [[ -e "$APP_TARGET" ]]; then
  mv "$APP_TARGET" "$TRASH_DIR/Gauge for Codex-$STAMP.app"
fi
if [[ -e "$AGENT_TARGET" ]]; then
  mv "$AGENT_TARGET" "$TRASH_DIR/com.qingtanlabs.gaugeforcodex-$STAMP.plist"
fi

if [[ "${1:-}" == "--purge" ]]; then
  defaults delete com.qingtanlabs.gaugeforcodex 2>/dev/null || true
  defaults delete group.com.qingtanlabs.gaugeforcodex 2>/dev/null || true
fi

echo "AgentReadout was moved to the Trash."
if [[ "${1:-}" != "--purge" ]]; then
  echo "Preferences were preserved. Run with --purge to remove them too."
fi
