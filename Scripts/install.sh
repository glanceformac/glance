#!/bin/bash
# Installs Glance for Mac from GitHub Releases, without the App Store or a paid Apple account.
#
#   curl -fsSL https://raw.githubusercontent.com/glanceformac/glance/main/Scripts/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/glanceformac/glance/main/Scripts/install.sh | bash -s -- --uninstall
#
# Options:
#   --version <x.y.z>       install that release instead of the latest
#   --local <Glance.zip>    install from a zip on disk (needs Glance.zip.sha256 next to it)
#   --dest <folder>         install somewhere other than /Applications
#   --extension-id <id>     also allow a Chrome extension ID you loaded from another folder
#   --no-chrome             skip the Chrome (Cinema mode) setup
#   --no-open               do not open Glance after installing
#   --uninstall             remove Glance.app and its Chrome setup (your settings are kept)
#
# What it does: downloads Glance.zip and its SHA-256 checksum, checks them, copies Glance.app to
# /Applications, removes the download quarantine flag from Glance.app only (the app is ad-hoc
# signed, not notarised), sets up the Chrome connection for Cinema mode and opens the app.
set -euo pipefail

REPO="glanceformac/glance"
BUNDLE_ID="app.glanceformac.glance"
APP_NAME="Glance.app"
DEST="/Applications"
VERSION=""
LOCAL_ZIP=""
EXTENSION_ID=""
CHROME=1
OPEN=1
MODE="install"

say()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:-}"; [ -n "$VERSION" ] || die "--version needs a value"; shift 2 ;;
    --local) LOCAL_ZIP="${2:-}"; [ -n "$LOCAL_ZIP" ] || die "--local needs a zip path"; shift 2 ;;
    --dest) DEST="${2:-}"; [ -n "$DEST" ] || die "--dest needs a folder"; shift 2 ;;
    --extension-id) EXTENSION_ID="${2:-}"; shift 2 ;;
    --no-chrome) CHROME=0; shift ;;
    --no-open) OPEN=0; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    -h|--help)
      echo "Usage: install.sh [--version x.y.z] [--local Glance.zip] [--dest folder] [--extension-id id] [--no-chrome] [--no-open] [--uninstall]"
      exit 0 ;;
    *) die "unknown option $1 (try --help)" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "Glance runs on macOS only."
TARGET="$DEST/$APP_NAME"

quit_glance() {
  # Only our own app: matched by its full executable path, never by a bare process name.
  if pgrep -f "$TARGET/Contents/MacOS/Glance" >/dev/null 2>&1; then
    info "Quitting the running Glance"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$TARGET/Contents/MacOS/Glance" >/dev/null 2>&1 || break; sleep 0.3; done
    pkill -f "$TARGET/Contents/MacOS/Glance" 2>/dev/null || true
  fi
  pkill -f "$TARGET/Contents/Library/LoginItems/GlanceBar.app" 2>/dev/null || true
}

is_glance() {
  [ -f "$1/Contents/Info.plist" ] &&
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null)" = "$BUNDLE_ID" ]
}

if [ "$MODE" = "uninstall" ]; then
  say "Uninstalling Glance from $DEST"
  if [ -e "$TARGET" ]; then
    is_glance "$TARGET" || die "$TARGET is not Glance for Mac ($BUNDLE_ID); leaving it alone."
    quit_glance
    if [ -x "$TARGET/Contents/Resources/install-chrome-host.sh" ]; then
      GLANCE_APP="$TARGET" "$TARGET/Contents/Resources/install-chrome-host.sh" --uninstall >/dev/null || true
    fi
    rm -rf "$TARGET"
    info "Removed $TARGET"
  else
    info "Glance is not installed in $DEST"
  fi
  info "Your settings were kept. To remove them too:"
  info "  defaults delete $BUNDLE_ID"
  info "  rm -rf \"\$HOME/Library/Application Support/Glance\" \"\$HOME/Library/Caches/Glance\""
  info "If you added the Claude Code hooks, remove them from ~/.claude/settings.json."
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/glance-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [ -n "$LOCAL_ZIP" ]; then
  say "Using local release $LOCAL_ZIP"
  [ -f "$LOCAL_ZIP" ] || die "no file at $LOCAL_ZIP"
  [ -f "$LOCAL_ZIP.sha256" ] || die "no checksum file at $LOCAL_ZIP.sha256"
  cp "$LOCAL_ZIP" "$WORK/Glance.zip"
  cp "$LOCAL_ZIP.sha256" "$WORK/Glance.zip.sha256"
else
  if [ -n "$VERSION" ]; then BASE="https://github.com/$REPO/releases/download/v${VERSION#v}"
  else BASE="https://github.com/$REPO/releases/latest/download"; fi
  say "Downloading Glance from $BASE"
  curl -fL --proto '=https' --tlsv1.2 --retry 2 -o "$WORK/Glance.zip" "$BASE/Glance.zip" || die "download failed: $BASE/Glance.zip"
  curl -fsSL --proto '=https' --tlsv1.2 --retry 2 -o "$WORK/Glance.zip.sha256" "$BASE/Glance.zip.sha256" || die "download failed: $BASE/Glance.zip.sha256"
fi

say "Checking the SHA-256 checksum"
EXPECTED="$(awk '{print $1; exit}' "$WORK/Glance.zip.sha256")"
[[ "$EXPECTED" =~ ^[0-9a-fA-F]{64}$ ]] || die "the checksum file is not valid"
ACTUAL="$(shasum -a 256 "$WORK/Glance.zip" | awk '{print $1}')"
[ "$(printf '%s' "$EXPECTED" | tr 'A-F' 'a-f')" = "$ACTUAL" ] || die "checksum mismatch (expected $EXPECTED, got $ACTUAL). Nothing was installed."
info "OK $ACTUAL"

say "Unpacking"
ditto -x -k "$WORK/Glance.zip" "$WORK/unzipped"
NEW="$WORK/unzipped/$APP_NAME"
is_glance "$NEW" || die "the download does not contain $APP_NAME with bundle id $BUNDLE_ID"
codesign --verify --deep --strict "$NEW" 2>/dev/null || die "the app's signature is broken"

say "Installing to $TARGET"
mkdir -p "$DEST" 2>/dev/null || true
[ -w "$DEST" ] || die "cannot write to $DEST. Run again with --dest \"\$HOME/Applications\", or fix the folder's permissions."
if [ -e "$TARGET" ]; then
  is_glance "$TARGET" || die "$TARGET exists and is not Glance for Mac; leaving it alone."
  quit_glance
  rm -rf "$TARGET"
fi
ditto "$NEW" "$TARGET"
# The app is ad-hoc signed, not notarised. Remove the download quarantine flag from Glance only,
# so macOS opens it without the "cannot be opened" warning. Nothing else is changed.
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
info "Installed $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist")"

if [ "$CHROME" = "1" ]; then
  say "Setting up Cinema mode for Chrome"
  GLANCE_APP="$TARGET" "$TARGET/Contents/Resources/install-chrome-host.sh" ${EXTENSION_ID:+--extension-id "$EXTENSION_ID"} | sed 's/^/    /'
fi

if [ "$OPEN" = "1" ]; then
  say "Opening Glance"
  open "$TARGET"
fi
say "Done. Glance lives in the menu bar (capsule icon). Uninstall with --uninstall."
