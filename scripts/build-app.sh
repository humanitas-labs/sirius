#!/usr/bin/env bash
# Builds the release binaries and wraps them in a signed Sirius.app.
#   scripts/build-app.sh [version]        → build/Sirius.app
#
# Layout:
#   Contents/MacOS/Sirius          the app (target SiriusApp)
#   Contents/Helpers/sirius        the CLI helper the agents run
#   Contents/Helpers/sirius-mcp    the MCP helper
#   Contents/Frameworks/Sparkle.framework   in-app updates
#
# The version (a release number such as v0.1.0 or 0.1.0) goes into
# CFBundleShortVersionString. Without one it comes from the latest v* tag,
# or 0.0.1. Apple requires one to three period-separated integers, so
# anything else fails the build. CFBundleVersion is the build number: the
# commit count of HEAD unless SIRIUS_BUILD_NUMBER says otherwise. Git
# provenance (git describe --tags --always --dirty) goes into the custom key
# SiriusGitRevision, never into the version keys.
#
# Signs with the first "Developer ID Application" identity in the keychain,
# with the hardened runtime, inside-out as Parrot does: Sparkle's XPC
# services, Autoupdate and Updater.app, then the framework, the helpers, and
# the app last. Without an identity the app is ad-hoc signed and every
# build is a new identity, so notification permission does not survive a
# rebuild; the script says so.
#
#   SIRIUS_SIGN_IDENTITY   signing identity (default: the keychain's Developer ID)
#   SIRIUS_TIMESTAMP=none  skip the secure timestamp (local builds, offline);
#                          notarization needs it, so releases leave this unset
#   SIRIUS_BUILD_DIR       output directory (default: build)
#   SIRIUS_BUILD_NUMBER    CFBundleVersion (default: git rev-list --count HEAD)
#   SIRIUS_GIT_REVISION    SiriusGitRevision (default: git describe --tags --always --dirty)

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo 0.0.1)}"
VERSION="${VERSION#v}"
BUILD_NUMBER="${SIRIUS_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
GIT_REVISION="${SIRIUS_GIT_REVISION:-$(git describe --tags --always --dirty 2>/dev/null || echo unknown)}"
OUT="${SIRIUS_BUILD_DIR:-build}"
APP="$OUT/Sirius.app"
BUNDLE_ID="com.humanitas.sirius"

NUMERIC='^[0-9]+(\.[0-9]+){0,2}$'
if ! [[ "$VERSION" =~ $NUMERIC ]]; then
    echo "version '$VERSION' is not one to three period-separated integers (e.g. 0.1.0); Git provenance goes in SIRIUS_GIT_REVISION" >&2
    exit 1
fi
if ! [[ "$BUILD_NUMBER" =~ $NUMERIC ]]; then
    echo "build number '$BUILD_NUMBER' is not numeric" >&2
    exit 1
fi

IDENTITY="${SIRIUS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"

echo "→ building sirius $VERSION (build $BUILD_NUMBER, $GIT_REVISION; release, arm64)"
for product in SiriusApp sirius sirius-mcp; do
    swift build -c release --arch arm64 --product "$product"
done
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/SiriusApp" "$APP/Contents/MacOS/Sirius"
# SwiftPM links Sparkle through @rpath and puts the framework beside the
# binary; in the bundle it lives in Contents/Frameworks.
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Sirius"
cp "$BIN/sirius" "$APP/Contents/Helpers/sirius"
cp "$BIN/sirius-mcp" "$APP/Contents/Helpers/sirius-mcp"
strip -x "$APP/Contents/MacOS/Sirius" "$APP/Contents/Helpers/sirius" "$APP/Contents/Helpers/sirius-mcp"
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp packaging/Info.plist "$APP/Contents/Info.plist"
# The agents' instructions template, seeded into each registry folder.
ditto packaging/agent "$APP/Contents/Resources/agent"
# The onboarding wordmark's face, Cormorant Garamond Medium (OFL), with its
# licence; the app registers it at launch of the onboarding.
ditto packaging/fonts "$APP/Contents/Resources/fonts"
# The onboarding sky's rendered clouds and bloom star.
ditto packaging/images "$APP/Contents/Resources/images"
# Each harness's default mark, <harness>.svg, copied into an agent's
# registry folder as icon.svg when onboarding registers it.
ditto packaging/marks "$APP/Contents/Resources/marks"
# The app icon: the menu bar's sparkle on the settings gradient, a first pass.
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -replace SiriusGitRevision -string "$GIT_REVISION" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# SwiftPM's resource bundles from ParrotCore's dependencies (swift-transformers'
# fallback tokenizer configs, swift-crypto's privacy manifest) are left out,
# as Parrot's build-app.sh leaves them out: their accessors look beside the
# .app, where a signed bundle can't hold anything. ParrotCore links no
# framework; Contents/Frameworks holds only Sirius's own Sparkle.

TIMESTAMP="--timestamp"
[ "${SIRIUS_TIMESTAMP:-}" = "none" ] && TIMESTAMP="--timestamp=none"

if [ -n "$IDENTITY" ]; then
    echo "→ signing as $IDENTITY"
    SIGN_AS="$IDENTITY"
else
    echo "! no Developer ID Application identity; ad-hoc signing."
    echo "  Permissions will not survive the next build, and the app can't be notarized."
    SIGN_AS="-"
    TIMESTAMP="--timestamp=none"
fi

# Inside-out: each nested bundle before the one that contains it, as in
# Sparkle's documentation and Parrot's build-app.sh. Downloader.xpc keeps
# its entitlements.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for nested in \
    "$SPARKLE/XPCServices/Installer.xpc" \
    "$SPARKLE/XPCServices/Downloader.xpc" \
    "$SPARKLE/Autoupdate" \
    "$SPARKLE/Updater.app" \
    "$APP/Contents/Frameworks/Sparkle.framework"; do
    codesign --force --options runtime $TIMESTAMP --preserve-metadata=entitlements \
        --sign "$SIGN_AS" "$nested"
done
# Then the helpers, then the app that contains them all.
for helper in sirius sirius-mcp; do
    codesign --force --options runtime $TIMESTAMP \
        --identifier "$BUNDLE_ID.$helper" \
        --sign "$SIGN_AS" "$APP/Contents/Helpers/$helper"
done
codesign --force --options runtime $TIMESTAMP \
    --entitlements packaging/Sirius.entitlements \
    --sign "$SIGN_AS" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
echo "  designated requirement: $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
echo "$APP"
