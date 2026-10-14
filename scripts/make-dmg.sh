#!/usr/bin/env bash
# Builds Sirius.app, notarizes and staples it, and packages it into a
# signed, notarized, stapled DMG with an Applications shortcut.
#   scripts/make-dmg.sh <version>   → dist/Sirius-<version>.dmg and .dmg.sha256
#
# A release runs it through scripts/make-release.sh, which adds the
# version-free Sirius.dmg and the signed Sparkle appcast.
#
# <version> is numeric (0.1.0 or v0.1.0); see scripts/build-app.sh. A run
# that fails at any step leaves an earlier dist/Sirius-<version>.dmg and its
# checksum as they were.
#
# The helpers in Contents/Helpers (sirius, sirius-mcp) are signed by
# scripts/build-app.sh with the same identity and the hardened runtime, so
# notarization covers them with the app. Each submission's notary log is
# kept in build/notary-<file>.json and its issues are printed, since Apple
# can accept a submission and still warn.
#
# Notary credentials, first match wins:
#
#   NOTARY_KEY=/path/to/key.p8     App Store Connect API key (CI)
#   NOTARY_KEY_ID=ABC123DEFG       its Key ID
#   NOTARY_ISSUER_ID=xxxxxxxx-...  the team's Issuer ID
#
# or a notarytool keychain profile, NOTARY_KEYCHAIN_PROFILE, default
# "parrot-notary": the team's profile, shared with Parrot
# (created once with `xcrun notarytool store-credentials parrot-notary`).
#
# SIRIUS_NOTARIZE=0 builds a signed but unnotarized DMG, for a quick look.
# Before anything is built or signed, scripts/compat-test.sh runs Sirius's
# launch arguments against the oldest supported, a middle and the latest
# Claude Code and Codex from npm; SIRIUS_SKIP_COMPAT=1 skips it.
# Needs a Developer ID Application identity; see scripts/build-app.sh.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/make-dmg.sh <version>}"
VERSION="${VERSION#v}"
OUT="dist"
DMG="$OUT/Sirius-$VERSION.dmg"
BUILD="${SIRIUS_BUILD_DIR:-build}"
APP="$BUILD/Sirius.app"
STAGE="$BUILD/dmg-stage"

IDENTITY="${SIRIUS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
if [ -z "$IDENTITY" ]; then
    echo "no Developer ID Application identity in the keychain; a release DMG needs one" >&2
    exit 1
fi
export SIRIUS_SIGN_IDENTITY="$IDENTITY"
unset SIRIUS_TIMESTAMP

NOTARIZE="${SIRIUS_NOTARIZE:-1}"

notary() {
    # notarytool with whichever credentials are set; $@ is the subcommand.
    if [ -n "${NOTARY_KEY:-}" ]; then
        xcrun notarytool "$@" \
            --key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}"
    else
        xcrun notarytool "$@" \
            --keychain-profile "${NOTARY_KEYCHAIN_PROFILE:-parrot-notary}"
    fi
}

notarize() {
    # $1: the file to submit. Waits, fails the build on rejection, and
    # prints the log's issues either way.
    local name result id status log
    name="$(basename "$1")"
    result="$BUILD/notary-$name.submit.json"
    log="$BUILD/notary-$name.json"
    notary submit "$1" --wait --output-format json > "$result" || true
    id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
    status="$(plutil -extract status raw -o - "$result" 2>/dev/null || true)"
    if [ -z "$id" ]; then
        echo "notarytool submit failed:" >&2
        cat "$result" >&2
        exit 1
    fi
    echo "  submission $id: $status"
    notary log "$id" "$log" >/dev/null
    if [ "$(plutil -extract issues raw -o - "$log" 2>/dev/null || echo null)" = "null" ] \
        || [ "$(plutil -extract issues raw -o - "$log" 2>/dev/null)" = "0" ]; then
        echo "  notary log: no issues ($log)"
    else
        echo "  notary log issues ($log):"
        plutil -extract issues json -o - "$log" 2>/dev/null || cat "$log"
        echo
    fi
    [ "$status" = "Accepted" ] || { echo "notarization of $name: $status" >&2; exit 1; }
}

if [ "${SIRIUS_SKIP_COMPAT:-0}" = 1 ]; then
    echo "! SIRIUS_SKIP_COMPAT=1: not checked against older Claude Code and Codex releases."
else
    echo "→ compat-test: Sirius's launch arguments against Claude Code and Codex releases"
    scripts/compat-test.sh
fi

scripts/build-app.sh "$VERSION"

if [ "$NOTARIZE" = 1 ]; then
    echo "→ notarizing the app"
    ZIP="$BUILD/Sirius-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarize "$ZIP"
    rm -f "$ZIP"
    # The ticket goes on the app, so it opens offline once copied out of
    # the DMG.
    xcrun stapler staple "$APP"
    spctl -a -vv -t exec "$APP"
else
    echo "! SIRIUS_NOTARIZE=0: signed but not notarized; Gatekeeper will block it on other Macs."
fi

# The new DMG is built, signed, notarized, stapled and assessed under a
# staging directory inside $OUT (same volume, so the final rename is
# atomic). Only then does it replace dist/Sirius-<version>.dmg and its
# checksum; any failure before that leaves the previous pair untouched.
mkdir -p "$OUT"
PENDING="$(mktemp -d "$OUT/.staging.XXXXXX")"
trap 'rm -rf "$PENDING"' EXIT
NEW_DMG="$PENDING/$(basename "$DMG")"

echo "→ packaging $NEW_DMG"
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Sirius.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Sirius" -srcfolder "$STAGE" -format UDZO -fs HFS+ -quiet "$NEW_DMG"
rm -rf "$STAGE"
codesign --sign "$IDENTITY" --timestamp "$NEW_DMG"
codesign --verify --strict --verbose=2 "$NEW_DMG"

if [ "$NOTARIZE" = 1 ]; then
    echo "→ notarizing the DMG"
    notarize "$NEW_DMG"
    xcrun stapler staple "$NEW_DMG"
    spctl -a -vv -t open --context context:primary-signature "$NEW_DMG"
fi

# The checksum names the published file, so it is computed under that name.
(cd "$PENDING" && shasum -a 256 "Sirius-$VERSION.dmg" > "Sirius-$VERSION.dmg.sha256")

echo "→ publishing $DMG"
mv -f "$NEW_DMG" "$DMG"
mv -f "$PENDING/Sirius-$VERSION.dmg.sha256" "$DMG.sha256"
cat "$DMG.sha256"
echo "$DMG"
