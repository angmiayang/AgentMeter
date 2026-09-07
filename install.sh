#!/bin/bash
# AgentMeter installer.
#
#   ./install.sh   build, install to /Applications, launch
#
# Builds from source on purpose. A locally built app is not quarantined by
# Gatekeeper, so there is no "unidentified developer" wall to click through —
# which a downloaded, un-notarised binary would hit.

set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd)"

APP="AgentMeter"

for a in "$@"; do
  case "$a" in
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

echo "AgentMeter installer"
echo

# --- requirements -----------------------------------------------------------
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MAJOR" -lt 13 ]; then
  echo "error: macOS 13 (Ventura) or later is required. You have $(sw_vers -productVersion)." >&2
  exit 1
fi

if ! command -v swiftc >/dev/null; then
  echo "The Xcode Command Line Tools are required to build the app."
  echo "Run this, let it finish, then run ./install.sh again:"
  echo
  echo "  xcode-select --install"
  exit 1
fi

if ! command -v iconutil >/dev/null; then
  echo "error: iconutil not found. It ships with the Xcode Command Line Tools." >&2
  exit 1
fi

# --- what it will be able to read -------------------------------------------
if [ ! -d "$HOME/.codex/sessions" ] && [ ! -d "$HOME/.claude/projects" ]; then
  echo "note: neither ~/.codex/sessions nor ~/.claude/projects exists yet."
  echo "      AgentMeter will install fine and show no readings until you have"
  echo "      used Claude Code or Codex at least once."
  echo
fi

# --- build and install -------------------------------------------------------
./scripts/build.sh --install

cat <<'MSG'

------------------------------------------------------------------
Done. The dial is in your menu bar — click it for the breakdown.

Nothing to approve in System Settings. AgentMeter only reads files
in your own home directory and makes one request to Anthropic's
account endpoint to read your Claude usage.

To start it at login, tick "Open At Login" in its menu.
------------------------------------------------------------------
MSG
echo
echo "To remove everything later: ./uninstall.sh"
exit 0
