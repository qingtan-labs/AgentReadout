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
INSTALL_DIR="$(mktemp -d "$HOME/Applications/.gauge-install.XXXXXX")"
STAGED_APP="$INSTALL_DIR/Gauge for Codex.app"
PREVIOUS_APP="$INSTALL_DIR/Previous Gauge for Codex.app"
ditto "$ROOT_DIR/build/Gauge for Codex.app" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
cp "$ROOT_DIR/com.qingtanlabs.gaugeforcodex.plist" "$AGENT_TARGET"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $APP_TARGET/Contents/MacOS/GaugeForCodex" "$AGENT_TARGET"

# Disable the pre-release CodexGauge login item without deleting it, so the
# migration is reversible and the two menu-bar processes cannot race.
launchctl bootout "$GUI_DOMAIN/$LEGACY_AGENT_LABEL" 2>/dev/null || true
if [[ -f "$LEGACY_AGENT_TARGET" && ! -e "$LEGACY_AGENT_TARGET.disabled" ]]; then
  mv "$LEGACY_AGENT_TARGET" "$LEGACY_AGENT_TARGET.disabled"
fi

launchctl bootout "$GUI_DOMAIN/$AGENT_LABEL" 2>/dev/null || true
if [[ -e "$APP_TARGET" ]]; then
  mv "$APP_TARGET" "$PREVIOUS_APP"
fi
if ! mv "$STAGED_APP" "$APP_TARGET"; then
  if [[ -e "$PREVIOUS_APP" ]]; then mv "$PREVIOUS_APP" "$APP_TARGET"; fi
  exit 1
fi
if ! launchctl bootstrap "$GUI_DOMAIN" "$AGENT_TARGET"; then
  sleep 1
  if ! launchctl bootstrap "$GUI_DOMAIN" "$AGENT_TARGET"; then
    mv "$APP_TARGET" "$STAGED_APP"
    if [[ -e "$PREVIOUS_APP" ]]; then mv "$PREVIOUS_APP" "$APP_TARGET"; fi
    exit 1
  fi
fi
launchctl kickstart -k "$GUI_DOMAIN/$AGENT_LABEL"
if [[ -e "$PREVIOUS_APP" ]]; then
  mkdir -p "$HOME/.Trash"
  TRASH_NAME="Gauge for Codex-previous-$(date +%Y%m%d-%H%M%S)-$(uuidgen).app"
  mv "$PREVIOUS_APP" "$HOME/.Trash/$TRASH_NAME"
fi
rmdir "$INSTALL_DIR"
echo "Installed: $APP_TARGET"
