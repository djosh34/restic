#!/bin/bash
# Opens the Full Disk Access pane by URL and records which pane appeared.
# Runs as the runner user, which has a GUI session on the hosted image.
set -u
OUT=${OUT:?}
mkdir -p "$OUT"
exec > >(tee -a "$OUT/pane.log") 2>&1
n=0
try_url() { # who url
  n=$((n + 1))
  echo "##### $n: $1 open $2"
  if [ "$1" = root ]; then sudo open "$2"; else open "$2"; fi
  echo "open exit=$?"
  sleep 10
  osascript -e 'tell application "System Events" to tell process "System Settings" to get name of every window' 2>&1 | sed 's/^/windows: /'
  osascript -e 'tell application "System Events" to tell process "System Settings" to get entire contents of window 1' 2>&1 |
    tr ',' '\n' | grep -i -E 'full disk|allow the applications|static text' | head -20 | sed 's/^/ui: /'
  screencapture -x "$OUT/pane-$n.png" && echo "screenshot pane-$n.png"
  osascript -e 'tell application "System Settings" to quit' 2>/dev/null
  sleep 3
}
try_url user "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
try_url user "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
try_url root "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
