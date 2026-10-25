#!/bin/zsh
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
LABEL="it.alessiolustri.clipboard-guard"
SUPPORT="$HOME/Library/Application Support/Clipboard Guard"
APP="$SUPPORT/Clipboard Guard.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGS="$HOME/Library/Logs/ClipboardGuard"
if [[ ! -x "$ROOT/Clipboard Guard.app/Contents/MacOS/ClipboardGuard" ]]; then
  print -u2 "The app has not been built. Run build.sh first."
  exit 1
fi
if [[ -e "$APP" ]]; then
  ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")
  [[ "$ID" == "$LABEL" ]] || { print -u2 "Unrecognized existing app: $APP"; exit 1; }
fi
/bin/launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
mkdir -p "$SUPPORT" "$HOME/Library/LaunchAgents" "$LOGS"
/usr/bin/ditto "$ROOT/Clipboard Guard.app" "$APP"
/usr/bin/ditto "$ROOT/README.md" "$SUPPORT/README.md"
/usr/bin/ditto "$ROOT/uninstall.command" "$SUPPORT/uninstall.command"
export CLIPGUARD_APP="$APP" CLIPGUARD_AGENT="$AGENT"
/usr/bin/python3 - <<'PY'
import os, plistlib
agent = {
    'Label': 'it.alessiolustri.clipboard-guard',
    'ProgramArguments': [os.environ['CLIPGUARD_APP'] + '/Contents/MacOS/ClipboardGuard'],
    'RunAtLoad': True,
    'KeepAlive': True,
    'ThrottleInterval': 10,
    'LimitLoadToSessionType': 'Aqua',
    'ProcessType': 'Interactive',
}
with open(os.environ['CLIPGUARD_AGENT'], 'wb') as f:
    plistlib.dump(agent, f)
os.chmod(os.environ['CLIPGUARD_AGENT'], 0o644)
PY
/usr/bin/plutil -lint "$AGENT"
/bin/launchctl enable "gui/$(id -u)/$LABEL"
/bin/launchctl bootstrap "gui/$(id -u)" "$AGENT"
/bin/launchctl print "gui/$(id -u)/$LABEL" | /usr/bin/awk '/state =|pid =|runs =|properties =/'
print "Installed. Allow Clipboard Guard notifications when macOS asks."
