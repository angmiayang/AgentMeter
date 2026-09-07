#!/bin/bash
# Removes AgentMeter completely: the app, its preferences and its caches.

set -uo pipefail

APP="AgentMeter"
BUNDLE_ID="local.agentmeter"

echo "Removing AgentMeter."
echo

osascript -e "tell application \"$APP\" to quit" 2>/dev/null || true
pkill -x "$APP" 2>/dev/null || true
sleep 1

if [ -d "/Applications/$APP.app" ]; then
  rm -rf "/Applications/$APP.app"
  echo "  removed /Applications/$APP.app"
fi

# Preferences, saved state and caches, including any from an earlier build that
# used a per-user bundle identifier.
for D in "$BUNDLE_ID" "local.$(id -un).agentmeter"; do
  for P in "$HOME/Library/Preferences/$D.plist" \
           "$HOME/Library/Saved Application State/$D.savedState" \
           "$HOME/Library/Caches/$D"; do
    if [ -e "$P" ]; then
      rm -rf "$P"
      echo "  removed $(basename "$P")"
    fi
  done
  if defaults read "$D" >/dev/null 2>&1; then
    defaults delete "$D" 2>/dev/null && echo "  removed preferences ($D)"
  fi
done

if [ -d build ]; then
  rm -rf build
  echo "  removed build output"
fi

echo
echo "Done."

cat <<'MSG'

Two things deliberately left alone:

  Your Claude and Codex data. AgentMeter only ever read the files under
  ~/.claude and ~/.codex; it created and modified nothing there, so there
  is nothing to clean up.

  Your keychain. AgentMeter stored no credential of its own. It read the
  existing "Claude Code-credentials" item at the moment of each check and
  kept nothing, so it has no entry to delete.

If "AgentMeter" still appears under System Settings > General > Login Items,
remove it there. That list is owned by macOS, not by this script.
MSG
exit 0
