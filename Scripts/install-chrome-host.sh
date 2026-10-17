#!/bin/bash
# Sets up Cinema mode's Chrome connection for Glance.
#
# 1. Copies the Glance Chrome extension out of Glance.app into
#    ~/Library/Application Support/Glance/Chrome Extension (a stable folder you load in Chrome).
# 2. Writes Chrome's native messaging host file, so only that extension can talk to Glance.
#
# The extension has no fixed key, so Chrome gives it an ID based on the folder it is loaded from.
# This script works that ID out from the folder, so you do not need to copy it by hand.
#
#   install-chrome-host.sh                       set up (run again after each update)
#   install-chrome-host.sh --extension-id <id>   also allow an ID you loaded from another folder
#   install-chrome-host.sh --uninstall           remove the host file and the extension copy
#
# Environment:
#   GLANCE_APP=/path/Glance.app   default /Applications/Glance.app
#   GLANCE_EXTENSION_SRC=<dir>    extension source (default: inside Glance.app)
set -euo pipefail

HOST_NAME="app.glanceformac.glance"
APP="${GLANCE_APP:-/Applications/Glance.app}"
SUPPORT="$HOME/Library/Application Support"
EXT_DIR="$SUPPORT/Glance/Chrome Extension"
# Chrome, Chrome Beta/Canary, Chromium, Brave, Edge and Vivaldi read native hosts from these folders.
BROWSERS=(
  "Google/Chrome" "Google/Chrome Beta" "Google/Chrome Canary" "Chromium"
  "BraveSoftware/Brave-Browser" "Microsoft Edge" "Vivaldi"
)

say() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

EXTRA_ID=""
MODE="install"
while [ $# -gt 0 ]; do
  case "$1" in
    --extension-id) EXTRA_ID="${2:-}"; shift 2 ;;
    --uninstall) MODE="uninstall"; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) die "unknown option $1 (try --help)" ;;
  esac
done

if [ "$MODE" = "uninstall" ]; then
  for b in "${BROWSERS[@]}"; do rm -f "$SUPPORT/$b/NativeMessagingHosts/$HOST_NAME.json"; done
  rm -rf "$EXT_DIR"
  say "Removed the Chrome host file and $EXT_DIR."
  say "Also remove the extension in chrome://extensions if it is still listed."
  exit 0
fi

if [ -n "$EXTRA_ID" ] && [[ ! "$EXTRA_ID" =~ ^[a-p]{32}$ ]]; then
  die "an extension ID is 32 letters from a to p (see chrome://extensions)"
fi

HOST_BIN="$APP/Contents/MacOS/glance-chrome-host"
[ -x "$HOST_BIN" ] || die "could not find $HOST_BIN. Install Glance first, or set GLANCE_APP."

SRC="${GLANCE_EXTENSION_SRC:-$APP/Contents/Resources/chrome-extension}"
[ -f "$SRC/manifest.json" ] || die "could not find the extension at $SRC"

mkdir -p "$SUPPORT/Glance"
chmod 700 "$SUPPORT/Glance"
rm -rf "$EXT_DIR"
ditto "$SRC" "$EXT_DIR"

# Chrome's ID for an unpacked extension without a key: SHA-256 of the folder's absolute path,
# first 32 hex digits, each mapped 0-f to a-p.
REAL_DIR="$(cd "$EXT_DIR" && pwd -P)"
ID="$(printf '%s' "$REAL_DIR" | shasum -a 256 | cut -c1-32 | tr '0-9a-f' 'a-p')"

ORIGINS="\"chrome-extension://$ID/\""
if [ -n "$EXTRA_ID" ] && [ "$EXTRA_ID" != "$ID" ]; then ORIGINS="$ORIGINS, \"chrome-extension://$EXTRA_ID/\""; fi

written=0
for b in "${BROWSERS[@]}"; do
  base="$SUPPORT/$b"
  # Google Chrome always gets the file; other browsers only if they are installed.
  if [ "$b" != "Google/Chrome" ] && [ ! -d "$base" ]; then continue; fi
  mkdir -p "$base/NativeMessagingHosts"
  cat > "$base/NativeMessagingHosts/$HOST_NAME.json" <<JSON
{
  "name": "$HOST_NAME",
  "description": "Glance Cinema mode bridge (colours and sound levels only)",
  "path": "$HOST_BIN",
  "type": "stdio",
  "allowed_origins": [$ORIGINS]
}
JSON
  written=$((written + 1))
done

say "Chrome connection ready ($written browser folder(s))."
say ""
say "Load the extension in Chrome once:"
say "  1. Open chrome://extensions and turn on Developer mode (top right)."
say "  2. Click Load unpacked, press Cmd+Shift+G, paste this folder and choose Select:"
say "     $EXT_DIR"
say "  3. Its ID should be $ID"
say "Restart Chrome if the extension popup says Glance is not reachable."
