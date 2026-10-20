#!/bin/bash
# Signs a release zip for Sparkle and adds it to the appcast (the update feed Glance checks daily).
#
#   Scripts/make-appcast.sh [options]
#
# Options:
#   --zip <file>        release zip (default dist/Glance.zip, made by Scripts/package-release.sh)
#   --appcast <file>    appcast to update in place; created from packaging/sparkle/appcast.xml if missing
#                       (default dist/appcast.xml). For a real release, point it at the site copy:
#                       --appcast ../glance-site/public/appcast.xml
#   --notes <file>      release notes: .html is used as is; .md or .txt lines become paragraphs,
#                       and lines starting with "- " become a list (default packaging/release-notes/<version>.md)
#   --url <url>         where the zip will be downloadable
#                       (default https://github.com/glanceformac/glance/releases/download/v<version>/Glance.zip)
#   --account <name>    Keychain account of the signing key (default app.glanceformac.glance)
#
# The EdDSA private key never leaves the Keychain: sign_update reads it there. Create it once with
#   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account app.glanceformac.glance
# and keep a backup of it (generate_keys -x) somewhere safe and offline, never in this repo.
# The version is read from the app inside the zip, so the feed always matches what users download.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
ZIP="$ROOT/dist/Glance.zip"
APPCAST="$ROOT/dist/appcast.xml"
NOTES=""
URL=""
ACCOUNT="app.glanceformac.glance"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --zip) ZIP="${2:-}"; shift 2 ;;
    --appcast) APPCAST="${2:-}"; shift 2 ;;
    --notes) NOTES="${2:-}"; shift 2 ;;
    --url) URL="${2:-}"; shift 2 ;;
    --account) ACCOUNT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "unknown option $1 (try --help)" ;;
  esac
done

[ -x "$BIN/sign_update" ] || (cd "$ROOT" && swift package resolve >/dev/null)
[ -x "$BIN/sign_update" ] || die "Sparkle tools not found in $BIN"
[ -f "$ZIP" ] || die "no zip at $ZIP (run Scripts/package-release.sh first)"

# Version and build number from the app inside the zip.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unzip -q -o "$ZIP" 'Glance.app/Contents/Info.plist' -d "$TMP" || die "Glance.app/Contents/Info.plist not found in $ZIP"
PL="$TMP/Glance.app/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PL")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PL")"
MINOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PL" 2>/dev/null || echo 14.0)"
KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PL" 2>/dev/null || true)"
[ -n "$KEY" ] || die "the app in $ZIP has no SUPublicEDKey; it could never install this update"
URL="${URL:-https://github.com/glanceformac/glance/releases/download/v$VERSION/Glance.zip}"
[ -n "$NOTES" ] || { [ -f "$ROOT/packaging/release-notes/$VERSION.md" ] && NOTES="$ROOT/packaging/release-notes/$VERSION.md"; }

# The Keychain key must be the one whose public half is in the app, or every user would reject it.
KC_KEY="$("$BIN/generate_keys" --account "$ACCOUNT" -p 2>/dev/null || true)"
[ "$KC_KEY" = "$KEY" ] || die "the Keychain key ($ACCOUNT) does not match SUPublicEDKey in the app ($KEY)"

echo "==> Signing $(basename "$ZIP") (Glance $VERSION, build $BUILD)"
SIG_ATTRS="$("$BIN/sign_update" --account "$ACCOUNT" "$ZIP")"   # sparkle:edSignature="..." length="..."
SIG="$(printf '%s' "$SIG_ATTRS" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
# Check it the way Glance will: against the public key inside the app (CryptoKit, no Keychain access).
cat > "$TMP/verify.swift" <<'SWIFT'
import CryptoKit
import Foundation
let a = CommandLine.arguments
guard let key = Data(base64Encoded: a[1]), let sig = Data(base64Encoded: a[2]),
      let file = FileManager.default.contents(atPath: a[3]),
      let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { exit(2) }
exit(pub.isValidSignature(sig, for: file) ? 0 : 1)
SWIFT
swift "$TMP/verify.swift" "$KEY" "$SIG" "$ZIP" 2>/dev/null || die "signature check against SUPublicEDKey failed"
echo "    signature OK (checked against SUPublicEDKey)"

[ -f "$APPCAST" ] || { mkdir -p "$(dirname "$APPCAST")"; cp "$ROOT/packaging/sparkle/appcast.xml" "$APPCAST"; }

echo "==> Updating $APPCAST"
/usr/bin/python3 -I - "$APPCAST" "$VERSION" "$BUILD" "$MINOS" "$URL" "$SIG_ATTRS" "${NOTES:-}" <<'PY'
import sys, html, re, email.utils, time
path, version, build, minos, url, sig_attrs, notes = sys.argv[1:8]

def notes_html(p):
    if not p:
        return "<p>Bug fixes and improvements.</p>"
    text = open(p, encoding="utf-8").read()
    if p.endswith(".html"):
        return text
    out, items = [], []
    def flush():
        if items:
            out.append("<ul>" + "".join("<li>%s</li>" % html.escape(i) for i in items) + "</ul>")
            items.clear()
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            flush(); continue
        if s.startswith("- ") or s.startswith("* "):
            items.append(s[2:])
        else:
            flush(); out.append("<p>%s</p>" % html.escape(s))
    flush()
    return "\n".join(out)

body = notes_html(notes).replace("]]>", "]]&gt;")
item = f"""    <item>
      <title>Glance {html.escape(version)}</title>
      <pubDate>{email.utils.formatdate(time.time(), usegmt=True)}</pubDate>
      <sparkle:version>{html.escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(minos)}</sparkle:minimumSystemVersion>
      <description><![CDATA[
{body}
      ]]></description>
      <enclosure url="{html.escape(url, quote=True)}" type="application/octet-stream" {sig_attrs} />
    </item>
"""
xml = open(path, encoding="utf-8").read()
# Replace an existing item for the same build (re-signing a rebuilt zip), else add newest first.
xml = re.sub(r"^[ \t]*<item>(?:(?!</item>).)*?<sparkle:version>%s</sparkle:version>(?:(?!</item>).)*</item>\n?" % re.escape(html.escape(build)), "", xml, flags=re.S | re.M)
m = re.search(r"^[ \t]*<item>", xml, flags=re.M)
if m:
    xml = xml[:m.start()] + item + xml[m.start():]
else:
    xml = xml.replace("  </channel>", item + "  </channel>", 1)
open(path, "w", encoding="utf-8").write(xml)
PY
xmllint --noout "$APPCAST" 2>/dev/null && echo "    appcast is valid XML" || echo "    (xmllint not available or reported a problem; check the file)"
echo "==> Done: Glance $VERSION -> $URL"
echo "    Upload the zip to that URL first, then publish $APPCAST at https://glanceformac.vercel.app/appcast.xml"
