#!/usr/bin/env bash
# Build, sign, and install a local Sirius.app for testing.
#   scripts/dev-install.sh
#
# macOS keys the notification permission to the app's code identity. An
# ad-hoc signature changes on every build, so each rebuild silently loses
# it. Signing with the Developer ID certificate and the fixed bundle ID
# com.humanitas.sirius (packaging/Info.plist) keeps one identity across
# rebuilds and releases.
#
# Installs to /Applications, or ~/Applications when /Applications is not
# writable. There is no link on the PATH: the agents reach sirius and
# sirius-mcp through Contents/Helpers, which the adapters put on their PATH.
#
# The version is the latest v* tag (or 0.0.1); the build number is the
# commit count; git describe goes into SiriusGitRevision. See build-app.sh.
#
# The new app is copied next to the destination and verified before
# anything is touched. A running copy is then quit, and the install stops
# with an error if it has not exited within SIRIUS_QUIT_TIMEOUT seconds.
# The swap is two renames on one volume: the old app aside, the new one in.
# The old app is deleted only after that succeeds, and put back if the
# second rename fails. A copy that was running is reopened in the
# background (open -g), so the install never takes focus.
#
#   SIRIUS_SIGN_IDENTITY  signing identity (default: the keychain's Developer ID)
#   SIRIUS_INSTALL_DIR    where Sirius.app goes
#   SIRIUS_NO_RESTART=1   don't quit and reopen a running copy
#   SIRIUS_QUIT_TIMEOUT   seconds to wait for a running copy to exit (default 15)
#
# The quit is a SIGTERM, which Sirius turns into an orderly quit that stops
# its agents first (#2). That takes up to 10 s, so the wait is longer.

set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${SIRIUS_INSTALL_DIR:-}" ]; then
    if [ -w /Applications ]; then
        SIRIUS_INSTALL_DIR=/Applications
    else
        SIRIUS_INSTALL_DIR="$HOME/Applications"
    fi
fi
BUILD="${SIRIUS_BUILD_DIR:-build}"
DEST="$SIRIUS_INSTALL_DIR/Sirius.app"
EXE="$DEST/Contents/MacOS/Sirius"
QUIT_TIMEOUT="${SIRIUS_QUIT_TIMEOUT:-15}"

TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo v0.0.1)"
GIT_REVISION="$(git describe --tags --always --dirty 2>/dev/null || echo unknown)"
SIRIUS_TIMESTAMP=none SIRIUS_BUILD_DIR="$BUILD" SIRIUS_GIT_REVISION="$GIT_REVISION" \
    scripts/build-app.sh "${TAG#v}"

running() { pgrep -f "^$EXE" >/dev/null 2>&1; }

echo "→ staging in $SIRIUS_INSTALL_DIR"
mkdir -p "$SIRIUS_INSTALL_DIR"
WORK="$(mktemp -d "$SIRIUS_INSTALL_DIR/.sirius-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/new" "$WORK/old"
ditto "$BUILD/Sirius.app" "$WORK/new/Sirius.app"
codesign --verify --deep --strict "$WORK/new/Sirius.app"

WAS_RUNNING=0
if [ -z "${SIRIUS_NO_RESTART:-}" ] && running; then
    WAS_RUNNING=1
    echo "→ quitting the running Sirius"
    pkill -TERM -f "^$EXE" || true
    deadline=$((SECONDS + QUIT_TIMEOUT))
    while running; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "Sirius at $DEST did not exit within ${QUIT_TIMEOUT}s; nothing was installed" >&2
            exit 1
        fi
        sleep 0.2
    done
fi

reopen() {
    if [ "$WAS_RUNNING" = 1 ]; then
        echo "→ reopening Sirius in the background"
        open -g "$DEST"
    fi
}

echo "→ installing to $DEST"
if [ -e "$DEST" ] && ! mv "$DEST" "$WORK/old/Sirius.app"; then
    echo "could not move the installed app aside; it is unchanged" >&2
    reopen
    exit 1
fi
if ! mv "$WORK/new/Sirius.app" "$DEST"; then
    echo "could not move the new app into $DEST" >&2
    if [ -e "$WORK/old/Sirius.app" ]; then
        if [ -e "$DEST" ] || ! mv "$WORK/old/Sirius.app" "$DEST"; then
            trap - EXIT
            echo "and could not restore the previous app; it is at $WORK/old/Sirius.app" >&2
            exit 1
        fi
        echo "restored the previous app" >&2
        reopen
    fi
    exit 1
fi
# The EXIT trap removes $WORK, and the old app in it.
reopen

echo "✓ installed Sirius $(plutil -extract CFBundleShortVersionString raw -o - "$DEST/Contents/Info.plist") ($GIT_REVISION) at $DEST"
