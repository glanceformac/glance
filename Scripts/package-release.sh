#!/bin/bash
# Builds a release of Glance and packs it for GitHub Releases.
#
#   Scripts/package-release.sh [version]          e.g. Scripts/package-release.sh 1.0.0
#
# Output in dist/ (or $DIST_DIR):
#   Glance.zip          Glance.app (universal, ad-hoc signed). The Chrome extension is inside it.
#   Glance.zip.sha256   checksum file in shasum format, used by Scripts/install.sh
#
# Options (environment):
#   ARCH=arm64|x86_64|universal   passed to build.sh (default universal)
#   SKIP_BUILD=1                  pack the existing build/Glance.app without rebuilding
#   DIST_DIR=<dir>                where to write the files (default dist/)
#   APPCAST=<file>                appcast to add this release to (default $DIST_DIR/appcast.xml);
#                                 for a real release: APPCAST=../glance-site/public/appcast.xml
#   NOTES=<file>                  release notes for the update window (default packaging/release-notes/<version>.md)
#   SKIP_APPCAST=1                only build and zip; no Sparkle signature or appcast entry
#
# Also writes, unless SKIP_APPCAST=1:
#   appcast.xml         the Sparkle update feed with this release on top, its zip signed with the
#                       EdDSA key from this Mac's Keychain (see Scripts/make-appcast.sh)
#
# There is no paid Apple Developer account, so the app is ad-hoc signed, not notarised.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-${GLANCE_VERSION:-1.0.0}}"
DIST="${DIST_DIR:-$ROOT/dist}"
APP="$ROOT/build/Glance.app"
ZIP="$DIST/Glance.zip"

[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}([.-][A-Za-z0-9]+)?$ ]] || { echo "Version must look like 1.0.0" >&2; exit 1; }

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "==> Building Glance $VERSION"
  GLANCE_VERSION="$VERSION" "$ROOT/build.sh"
fi
[ -d "$APP" ] || { echo "No app at $APP. Run without SKIP_BUILD=1." >&2; exit 1; }

echo "==> Checking the app"
ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[ "$ID" = "app.glanceformac.glance" ] || { echo "Unexpected bundle id $ID" >&2; exit 1; }
# build.sh ad-hoc signs the bundle; make sure the signature is still valid before packing.
codesign --verify --deep --strict "$APP"
echo "    bundle id $ID, version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"), archs: $(lipo -archs "$APP/Contents/MacOS/Glance")"

echo "==> Zipping"
mkdir -p "$DIST"
rm -f "$ZIP" "$ZIP.sha256"
# ditto keeps the bundle structure, symlinks and signature intact; Glance.app is at the zip root.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

if [ "${SKIP_APPCAST:-0}" != "1" ]; then
  "$ROOT/Scripts/make-appcast.sh" --zip "$ZIP" --appcast "${APPCAST:-$DIST/appcast.xml}" ${NOTES:+--notes "$NOTES"}
fi

SHA="$(cut -d' ' -f1 "$ZIP.sha256")"
echo "==> Done"
echo "    $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "    $ZIP.sha256  $SHA"
echo "    Upload both to a GitHub release tagged v$VERSION, then publish appcast.xml (see Scripts/make-appcast.sh)."
echo "    Homebrew cask: version \"$VERSION\", sha256 \"$SHA\""
