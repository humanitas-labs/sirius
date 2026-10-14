#!/usr/bin/env bash
# Builds the release DMG and the Sparkle appcast for in-app updates.
#   scripts/make-release.sh <version>   → dist/release/Sirius.dmg
#                                         dist/release/Sirius.dmg.sha256
#                                         dist/release/appcast.xml
#
# Runs scripts/make-dmg.sh <version> (signed, notarized, stapled), then
# copies the DMG under a version-free name, so that
# releases/latest/download/Sirius.dmg and .../appcast.xml always name the
# newest release. The appcast's enclosure points at the tag's own asset,
# releases/download/v<version>/Sirius.dmg, which never changes once
# published. Sparkle's generate_appcast signs the DMG (the enclosure's
# edSignature) and the feed itself (the app sets SURequireSignedFeed) with
# the EdDSA key in the login keychain under the account "sirius"; its
# public half is SUPublicEDKey in packaging/Info.plist. The feed holds only
# this release: every client reads the latest one. sparkle:version is the
# app's CFBundleVersion (the commit count, see build-app.sh),
# sparkle:shortVersionString its marketing version, and
# sparkle:minimumSystemVersion its LSMinimumSystemVersion.
#
# The first run on a Mac asks, in a keychain dialog, to let generate_appcast
# and sign_update use the "sirius" key; choose Always Allow for each. The
# private key never leaves the keychain: nothing here exports or prints it.
#
# The script neither tags, uploads nor pushes. Publishing is:
#   gh release create v<version> --title "Sirius <version>" \
#       dist/release/Sirius.dmg dist/release/appcast.xml
#
#   SIRIUS_DMG=<path>                  use this DMG instead of running make-dmg.sh
#   SIRIUS_DOWNLOAD_URL_PREFIX=<url/>  the enclosure's URL prefix (default
#                                      https://github.com/humanitas-labs/sirius/releases/download/v<version>/)
#   SIRIUS_RELEASE_DIR                 output directory (default dist/release)
#   SIRIUS_ED_KEY_FILE=<path>          sign with this private key file instead
#                                      of the keychain's (the update test's
#                                      throwaway key; never the release key)
#
# Other variables pass through to make-dmg.sh (SIRIUS_NOTARIZE,
# SIRIUS_SKIP_COMPAT, NOTARY_*).

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/make-release.sh <version>}"
VERSION="${VERSION#v}"
REPO="https://github.com/humanitas-labs/sirius"
PREFIX="${SIRIUS_DOWNLOAD_URL_PREFIX:-$REPO/releases/download/v$VERSION/}"
RELEASE="${SIRIUS_RELEASE_DIR:-dist/release}"
ACCOUNT="sirius"

if [ -n "${SIRIUS_DMG:-}" ]; then
    DMG="$SIRIUS_DMG"
else
    scripts/make-dmg.sh "$VERSION"
    DMG="dist/Sirius-$VERSION.dmg"
fi
[ -f "$DMG" ] || { echo "no DMG at $DMG" >&2; exit 1; }

# Sparkle's tools come with the SwiftPM artifact (Package.swift pins the version).
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
[ -x "$SPARKLE_BIN/generate_appcast" ] || swift package resolve
for tool in generate_appcast sign_update generate_keys; do
    [ -x "$SPARKLE_BIN/$tool" ] || { echo "no $SPARKLE_BIN/$tool" >&2; exit 1; }
done

# The signing key: the keychain's, or a key file.
if [ -n "${SIRIUS_ED_KEY_FILE:-}" ]; then
    KEY=(--ed-key-file "$SIRIUS_ED_KEY_FILE")
else
    KEY=(--account "$ACCOUNT")
fi

# The DMG must hold the version asked for, with a numeric build number,
# and trust the key that signs it.
MOUNT="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" -quiet "$DMG"
PLIST="$MOUNT/Sirius.app/Contents/Info.plist"
SHORT="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$PLIST")"
MIN_SYSTEM="$(plutil -extract LSMinimumSystemVersion raw -o - "$PLIST")"
APP_KEY="$(plutil -extract SUPublicEDKey raw -o - "$PLIST")"
hdiutil detach -quiet "$MOUNT"
rmdir "$MOUNT"
[ "$SHORT" = "$VERSION" ] || { echo "$DMG holds Sirius $SHORT, not $VERSION" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "build number '$BUILD_NUMBER' is not numeric" >&2; exit 1; }
# The signing key's public half must be the app's SUPublicEDKey, or the
# release ships an update every client refuses. generate_keys -p prints the
# public half only.
if [ -n "${SIRIUS_ED_KEY_FILE:-}" ]; then
    SIGNING_KEY="$(swift - "$SIRIUS_ED_KEY_FILE" <<'SWIFT'
import CryptoKit
import Foundation
let text = (try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)) ?? ""
guard let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed.prefix(32)) else { exit(1) }
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
)" || { echo "$SIRIUS_ED_KEY_FILE is not a base64 Ed25519 key" >&2; exit 1; }
else
    SIGNING_KEY="$("$SPARKLE_BIN/generate_keys" --account "$ACCOUNT" -p)"
fi
if [ "$SIGNING_KEY" != "$APP_KEY" ]; then
    echo "the signing key's public half ($SIGNING_KEY) is not the app's SUPublicEDKey ($APP_KEY)" >&2
    exit 1
fi

# Written under a staging directory and moved into place only once checked.
mkdir -p "$(dirname "$RELEASE")"
STAGE="$(mktemp -d "$(dirname "$RELEASE")/.release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp "$DMG" "$STAGE/Sirius.dmg"

echo "→ writing the appcast for Sirius $VERSION (build $BUILD_NUMBER)"
"$SPARKLE_BIN/generate_appcast" "${KEY[@]}" \
    --download-url-prefix "$PREFIX" \
    --full-release-notes-url "$REPO/releases/tag/v$VERSION" \
    --link "$REPO" \
    --maximum-versions 1 \
    "$STAGE"

APPCAST="$STAGE/appcast.xml"
SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$APPCAST")"
[ -n "$SIGNATURE" ] || { echo "appcast.xml has no edSignature" >&2; exit 1; }
"$SPARKLE_BIN/sign_update" "${KEY[@]}" --verify "$STAGE/Sirius.dmg" "$SIGNATURE"
"$SPARKLE_BIN/sign_update" "${KEY[@]}" --verify "$APPCAST"
grep -q "url=\"${PREFIX}Sirius.dmg\"" "$APPCAST" || { echo "appcast.xml's enclosure is not ${PREFIX}Sirius.dmg" >&2; exit 1; }
grep -q "<sparkle:version>$BUILD_NUMBER</sparkle:version>" "$APPCAST" || { echo "appcast.xml lacks sparkle:version $BUILD_NUMBER" >&2; exit 1; }
grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST" || { echo "appcast.xml lacks shortVersionString $VERSION" >&2; exit 1; }
grep -q "<sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>" "$APPCAST" || { echo "appcast.xml lacks minimumSystemVersion $MIN_SYSTEM" >&2; exit 1; }
(cd "$STAGE" && shasum -a 256 Sirius.dmg > Sirius.dmg.sha256)

echo "→ publishing $RELEASE"
mkdir -p "$RELEASE"
mv -f "$STAGE/Sirius.dmg" "$STAGE/Sirius.dmg.sha256" "$APPCAST" "$RELEASE/"
cat "$RELEASE/appcast.xml"
cat "$RELEASE/Sirius.dmg.sha256"
echo "Upload $RELEASE/Sirius.dmg and $RELEASE/appcast.xml to the GitHub release v$VERSION."
