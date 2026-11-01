#!/bin/bash
# Stop and remove TPScroll.  --purge also removes settings, the log and its privacy grants.
set -euo pipefail
LABEL=io.github.lebdron.tpscroll
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/TPScroll.app"
if [[ "${1:-}" == "--purge" ]]; then
  defaults delete "$LABEL" 2>/dev/null || true
  rm -f "$HOME/Library/Logs/tpscroll.log"
  tccutil reset ListenEvent "$LABEL" 2>/dev/null || true
  tccutil reset Accessibility "$LABEL" 2>/dev/null || true
fi
echo "TPScroll removed (it switched the keyboard back to its default mode on exit)."
