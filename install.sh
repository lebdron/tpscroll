#!/bin/bash
# Build TPScroll, install it to ~/Applications and start it at login via a LaunchAgent.
#   ./install.sh                     build + install + (re)start
#   ./install.sh --reset-permissions also clear TPScroll's stale privacy grants (needed after an ad-hoc rebuild)
set -euo pipefail
cd "$(dirname "$0")"
LABEL=io.github.lebdron.tpscroll
APP_DST="$HOME/Applications/TPScroll.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/tpscroll.log"
DOMAIN="gui/$(id -u)"

./build.sh tpscroll

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# the old instance restores the keyboard's default mode before exiting; wait until launchd has really unloaded it
for _ in $(seq 50); do launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break; sleep 0.1; done
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
rm -rf "$APP_DST"; cp -R build/TPScroll.app "$APP_DST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DST" || true

if [[ "${1:-}" == "--reset-permissions" ]]; then
  tccutil reset ListenEvent "$LABEL" || true
  tccutil reset Accessibility "$LABEL" || true
fi
# a new signature needs a new grant: allow TPScroll to show the Input Monitoring prompt once more
defaults delete "$LABEL" askedInputMonitoring 2>/dev/null || true

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP_DST/Contents/MacOS/tpscroll</string></array>
  <key>AssociatedBundleIdentifiers</key><string>$LABEL</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PLIST
launchctl bootstrap "$DOMAIN" "$PLIST"

cat <<MSG

TPScroll installed and started. Log: $LOG

Grant TPScroll two permissions in System Settings › Privacy & Security
(it waits and picks them up by itself):
  1. Input Monitoring
  2. Accessibility  (shown as "Device Control and Data Access" on some macOS versions)
The prompts do not always add a new app to the lists. If TPScroll is missing, click "+",
press ⌘⇧G and add $APP_DST.
After an ad-hoc rebuild, old entries are stale: rerun with --reset-permissions and grant again.
MSG
