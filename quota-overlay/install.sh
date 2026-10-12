#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
APP_TARGET="$HOME/Applications/AgentReadout.app"
LEGACY_APP_TARGET="$HOME/Applications/Gauge for Codex.app"
AGENT_TARGET="$HOME/Library/LaunchAgents/com.qingtanlabs.gaugeforcodex.plist"
LEGACY_AGENT_TARGET="$HOME/Library/LaunchAgents/com.local.codexgauge.plist"
GUI_DOMAIN="gui/$(id -u)"
AGENT_LABEL="com.qingtanlabs.gaugeforcodex"
LEGACY_AGENT_LABEL="com.local.codexgauge"

"$ROOT_DIR/build.sh"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
if [[ -e "$APP_TARGET" && -e "$LEGACY_APP_TARGET" ]]; then
  echo "Both AgentReadout and the legacy Gauge for Codex app exist. Resolve the duplicate before installing." >&2
  exit 1
fi
EXISTING_APP="$APP_TARGET"
if [[ -e "$LEGACY_APP_TARGET" ]]; then
  EXISTING_APP="$LEGACY_APP_TARGET"
fi
if [[ -e "$EXISTING_APP" ]] &&
   [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$EXISTING_APP/Contents/Info.plist" 2>/dev/null || true)" != "com.qingtanlabs.gaugeforcodex" ]]; then
  echo "Refusing to replace an app with an unexpected bundle identifier: $EXISTING_APP" >&2
  exit 1
fi
INSTALL_DIR="$(mktemp -d "$HOME/Applications/.gauge-install.XXXXXX")"
STAGED_APP="$INSTALL_DIR/AgentReadout.app"
PREVIOUS_APP="$INSTALL_DIR/Previous AgentReadout.app"
ditto "$ROOT_DIR/build/Gauge for Codex.app" "$STAGED_APP"
# A Command Line Tools-only build cannot compile WidgetKit. Keep a compatible
# already-installed extension instead of silently removing the user's widget.
EXISTING_WIDGET="$EXISTING_APP/Contents/PlugIns/GaugeForCodexWidget.appex"
STAGED_WIDGET="$STAGED_APP/Contents/PlugIns/GaugeForCodexWidget.appex"
if [[ ! -e "$STAGED_WIDGET" && -d "$EXISTING_WIDGET" ]]; then
  HOST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$STAGED_APP/Contents/Info.plist")"
  WIDGET_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$EXISTING_WIDGET/Contents/Info.plist")"
  WIDGET_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$EXISTING_WIDGET/Contents/Info.plist")"
  if [[ "$HOST_BUILD" == "$WIDGET_BUILD" && "$WIDGET_ID" == "com.qingtanlabs.gaugeforcodex.widget" ]] &&
     codesign --verify --strict "$EXISTING_WIDGET"; then
    mkdir -p "$STAGED_APP/Contents/PlugIns"
    ditto "$EXISTING_WIDGET" "$STAGED_WIDGET"
    codesign --force --sign - "$STAGED_WIDGET"
    codesign --force --sign - "$STAGED_APP"
    echo "Preserved the existing Codex-only native widget extension."
  fi
fi
codesign --verify --deep --strict "$STAGED_APP"
LOGIN_AT_LOAD=false
if [[ -f "$AGENT_TARGET" ]]; then
  LOGIN_AT_LOAD="$(/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "$AGENT_TARGET" 2>/dev/null || echo false)"
  [[ "$LOGIN_AT_LOAD" == true ]] || LOGIN_AT_LOAD=false
fi
cp "$ROOT_DIR/com.qingtanlabs.gaugeforcodex.plist" "$AGENT_TARGET"
/usr/libexec/PlistBuddy -c "Set :RunAtLoad $LOGIN_AT_LOAD" "$AGENT_TARGET"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $APP_TARGET/Contents/MacOS/GaugeForCodex" "$AGENT_TARGET"

# Disable the pre-release CodexGauge login item without deleting it, so the
# migration is reversible and the two menu-bar processes cannot race.
launchctl bootout "$GUI_DOMAIN/$LEGACY_AGENT_LABEL" 2>/dev/null || true
if [[ -f "$LEGACY_AGENT_TARGET" && ! -e "$LEGACY_AGENT_TARGET.disabled" ]]; then
  mv "$LEGACY_AGENT_TARGET" "$LEGACY_AGENT_TARGET.disabled"
fi

launchctl bootout "$GUI_DOMAIN/$AGENT_LABEL" 2>/dev/null || true
"$STAGED_APP/Contents/Helpers/GaugeForCodexUpdater" --stop-widget "$EXISTING_APP"
restore_previous_install() {
  launchctl bootout "$GUI_DOMAIN/$AGENT_LABEL" 2>/dev/null || true
  if [[ -e "$PREVIOUS_APP" ]]; then
    if [[ -e "$APP_TARGET" ]]; then mv "$APP_TARGET" "$STAGED_APP"; fi
    mv "$PREVIOUS_APP" "$EXISTING_APP"
    /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $EXISTING_APP/Contents/MacOS/GaugeForCodex" "$AGENT_TARGET" || true
    "$STAGED_APP/Contents/Helpers/GaugeForCodexUpdater" --register-app "$EXISTING_APP" || true
    launchctl bootstrap "$GUI_DOMAIN" "$AGENT_TARGET" || true
    launchctl kickstart "$GUI_DOMAIN/$AGENT_LABEL" || true
  fi
  echo "Installation failed; previous app restored when available. Staging retained: $INSTALL_DIR" >&2
}
if [[ -e "$EXISTING_APP" ]]; then
  mv "$EXISTING_APP" "$PREVIOUS_APP"
fi
if ! mv "$STAGED_APP" "$APP_TARGET"; then
  restore_previous_install
  exit 1
fi
if ! "$APP_TARGET/Contents/Helpers/GaugeForCodexUpdater" --register-app "$APP_TARGET"; then
  restore_previous_install
  exit 1
fi
if ! launchctl bootstrap "$GUI_DOMAIN" "$AGENT_TARGET"; then
  sleep 1
  if ! launchctl bootstrap "$GUI_DOMAIN" "$AGENT_TARGET"; then
    restore_previous_install
    exit 1
  fi
fi
if ! launchctl kickstart -k "$GUI_DOMAIN/$AGENT_LABEL"; then
  restore_previous_install
  exit 1
fi
if [[ -e "$PREVIOUS_APP" ]]; then
  mkdir -p "$HOME/.Trash"
  TRASH_NAME="AgentReadout-previous-$(date +%Y%m%d-%H%M%S)-$(uuidgen).app"
  mv "$PREVIOUS_APP" "$HOME/.Trash/$TRASH_NAME"
fi
# chronod keeps the old extension executable path in its per-process launchd
# domain. After a bundle rename, registration alone cannot replace that job;
# restart only this user's widget services so the new path is discovered.
if [[ "$EXISTING_APP" == "$LEGACY_APP_TARGET" ]]; then
  if ! pkill -TERM -u "$(id -u)" -x chronod; then
    echo "Widget service could not be restarted. Log out and back in if widgets stay stale." >&2
  fi
  pkill -TERM -u "$(id -u)" -x NotificationCenter 2>/dev/null || true
fi
rmdir "$INSTALL_DIR"
echo "Installed: $APP_TARGET"
