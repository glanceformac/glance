#!/bin/bash
# Builds build/Glance.app (ad-hoc signed). No Xcode needed: Swift Package Manager + clang.
#   ./build.sh            build build/Glance.app
#   ./build.sh install    also quit Glance, replace /Applications/Glance.app and launch it
# ARCH=universal (default) builds for Apple silicon and Intel; ARCH=arm64 or ARCH=x86_64 builds one.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
ARCH="${ARCH:-universal}"
case "$ARCH" in
  universal) ARCHS=(arm64 x86_64) ;;
  arm64|x86_64) ARCHS=("$ARCH") ;;
  *) echo "ARCH must be universal, arm64 or x86_64" >&2; exit 1 ;;
esac
PRODUCTS=(Glance glance-hook glance-chrome-host GlanceBar)
APP="$ROOT/build/Glance.app"
MRA_SRC="$ROOT/Vendor/mediaremote-adapter"
OBJ="$ROOT/build/obj"
BUNDLE_ID="app.glanceformac.glance"
VERSION="${GLANCE_VERSION:-1.1.0}"
# Sparkle compares CFBundleVersion, so it follows the version (1.1.0 > 1.0.0 > the old "1").
BUILD_NUMBER="${GLANCE_BUILD:-$VERSION}"

# Each architecture is built on its own (multi-arch swift build needs full Xcode), then lipo
# joins them into universal binaries.
BIN="$ROOT/build/bin"
rm -rf "$BIN"; mkdir -p "$BIN"
for a in "${ARCHS[@]}"; do
  echo "==> swift build (release, $a)"
  swift build -c release --arch "$a"
done
for p in "${PRODUCTS[@]}"; do
  inputs=()
  for a in "${ARCHS[@]}"; do inputs+=("$(swift build -c release --arch "$a" --show-bin-path)/$p"); done
  lipo -create "${inputs[@]}" -output "$BIN/$p"
done

echo "==> assembling Glance.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/mediaremote" "$OBJ"
cp "$BIN/Glance" "$APP/Contents/MacOS/Glance"
cp "$BIN/glance-hook" "$APP/Contents/MacOS/glance-hook"
cp "$BIN/glance-chrome-host" "$APP/Contents/MacOS/glance-chrome-host"

echo "==> GlanceBar.app (Touch Bar Control Strip helper, login item)"
BAR="$APP/Contents/Library/LoginItems/GlanceBar.app"
mkdir -p "$BAR/Contents/MacOS"
cp "$BIN/GlanceBar" "$BAR/Contents/MacOS/GlanceBar"
cat > "$BAR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>GlanceBar</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID.bar</string>
<key>CFBundleExecutable</key><string>GlanceBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
# Test builds only: GLANCE_BUNDLE_ID gives a separate app identity (own settings, own Sparkle state).
if [ -n "${GLANCE_BUNDLE_ID:-}" ]; then
  BUNDLE_ID="$GLANCE_BUNDLE_ID"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID.bar" "$BAR/Contents/Info.plist"
fi
cp "$ROOT/Resources/Glance.icns" "$APP/Contents/Resources/Glance.icns"
# Built-in character packs (Kitsune, Pocket ninja). Personal packs never ship: they live in
# ~/Library/Application Support/Glance/Characters on the user's own Mac.
cp -R "$ROOT/Resources/Characters" "$APP/Contents/Resources/Characters"

echo "==> Sparkle.framework (in-app updates, MIT)"
SPARKLE_FW="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "$SPARKLE_FW" ] || { echo "Sparkle.framework not found; run: swift package resolve" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"   # ditto keeps the framework symlinks
# Glance is not sandboxed, so Sparkle's XPC services are not used (Sparkle docs: safe to remove).
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
cp "$ROOT/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP/Contents/Resources/LICENSE-Sparkle.txt"

echo "==> building MediaRemoteAdapter.framework (ungive/mediaremote-adapter, BSD-3-Clause)"
FW="$APP/Contents/Resources/mediaremote/MediaRemoteAdapter.framework"
mkdir -p "$FW/Versions/A/Resources"
CLANG_ARCHS=(); for a in "${ARCHS[@]}"; do CLANG_ARCHS+=(-arch "$a"); done
clang "${CLANG_ARCHS[@]}" -dynamiclib -O2 -fobjc-arc -fvisibility=default \
  -I"$MRA_SRC/include" -I"$MRA_SRC/src" \
  "$MRA_SRC"/src/adapter/*.m "$MRA_SRC/src/private/MediaRemote.m" "$MRA_SRC"/src/utility/*.m \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
  -o "$FW/Versions/A/MediaRemoteAdapter" 2> "$OBJ/mra-warnings.txt" || { cat "$OBJ/mra-warnings.txt"; exit 1; }
ln -sfn A "$FW/Versions/Current"
ln -sfn Versions/Current/MediaRemoteAdapter "$FW/MediaRemoteAdapter"
ln -sfn Versions/Current/Resources "$FW/Resources"
cat > "$FW/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
<key>CFBundleIdentifier</key><string>com.vandenbe.MediaRemoteAdapter</string>
<key>CFBundleName</key><string>MediaRemoteAdapter</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>0.1.0</string>
</dict></plist>
PLIST
cp "$MRA_SRC/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/mediaremote/"
cp "$MRA_SRC/LICENSE" "$APP/Contents/Resources/mediaremote/LICENSE-mediaremote-adapter.txt"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$ROOT/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md"
# Cinema mode: the Chrome extension and the script that connects it, so a downloaded app has both.
ditto "$ROOT/chrome-extension" "$APP/Contents/Resources/chrome-extension"
cp "$ROOT/Scripts/install-chrome-host.sh" "$APP/Contents/Resources/install-chrome-host.sh"
chmod +x "$APP/Contents/Resources/install-chrome-host.sh"

echo "==> ad-hoc codesign"
codesign --force --sign - "$FW"
SPK="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$SPK/Versions/B/Autoupdate"
codesign --force --sign - "$SPK/Versions/B/Updater.app"
codesign --force --sign - "$SPK"
# Ad-hoc signatures normally get a cdhash-based designated requirement, which changes on
# every build, so macOS (TCC) treats each rebuild as a new app and asks for Calendar /
# Location / Automation again. Pin the designated requirement to the bundle identifier so
# permissions granted once persist across rebuilds. No certificate or Keychain change needed.
sign() { codesign --force --sign - --identifier "$1" --requirements "=designated => identifier \"$1\"" "$2"; }
sign "$BUNDLE_ID.chromehost" "$APP/Contents/MacOS/glance-chrome-host"
sign "$BUNDLE_ID.bar" "$BAR"
sign "$BUNDLE_ID.hook" "$APP/Contents/MacOS/glance-hook"
sign "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP" && echo "signature OK"

echo "==> done: $APP"

# ./build.sh install  ->  quit Glance, replace /Applications/Glance.app, launch it.
if [ "${1:-}" = "install" ]; then
  echo "==> installing to /Applications"
  pkill -x Glance 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Glance >/dev/null || break; sleep 0.3; done
  pkill -9 -x Glance 2>/dev/null || true
  pkill -x GlanceBar 2>/dev/null || true      # old helper; the new Glance starts the new one
  rm -rf /Applications/Glance.app
  ditto "$APP" /Applications/Glance.app        # ditto keeps the signature intact
  codesign --verify --strict /Applications/Glance.app && echo "installed signature OK"
  # Chrome native messaging host and extension copy for Cinema mode (see README).
  GLANCE_APP=/Applications/Glance.app "$ROOT/Scripts/install-chrome-host.sh" ${GLANCE_EXTENSION_ID:+--extension-id "$GLANCE_EXTENSION_ID"}
  open /Applications/Glance.app
  echo "==> launched /Applications/Glance.app"
  # The new Glance re-registers the Touch Bar helper's login item for the new bundle and
  # starts the new GlanceBar (see IslandBarHelper.update).
fi
