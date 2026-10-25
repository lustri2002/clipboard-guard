#!/bin/zsh
set -euo pipefail
LABEL="it.alessiolustri.clipboard-guard"
SUPPORT="$HOME/Library/Application Support/Clipboard Guard"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
/bin/launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
DEST="$HOME/.Trash/Clipboard Guard-$STAMP"
mkdir -p "$DEST"
[[ ! -e "$AGENT" ]] || mv "$AGENT" "$DEST/"
[[ ! -e "$SUPPORT" ]] || mv "$SUPPORT" "$DEST/"
print "Monitoring removed. Files moved to Trash; logs kept in ~/Library/Logs/ClipboardGuard."
print "Clipboard sharing remains enabled."
