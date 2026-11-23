#!/usr/bin/env bash
# Points the Homebrew cask at a release.
#   scripts/bump-cask.sh <version> [cask]   → rewrites version and sha256
#
# Run after scripts/make-release.sh <version>: the checksum is read from
# dist/release/Sirius.dmg.sha256, which is the DMG the release uploads. The
# cask defaults to this repo's copy, packaging/homebrew/Casks/sirius.rb;
# name the tap's copy to bump that one. Nothing is committed or pushed.
#
#   SIRIUS_RELEASE_DIR   where the release was written (default dist/release)

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/bump-cask.sh <version> [cask]}"
VERSION="${VERSION#v}"
CASK="${2:-packaging/homebrew/Casks/sirius.rb}"
SUM_FILE="${SIRIUS_RELEASE_DIR:-dist/release}/Sirius.dmg.sha256"

[ -f "$CASK" ] || { echo "no cask at $CASK" >&2; exit 1; }
[ -f "$SUM_FILE" ] || { echo "no $SUM_FILE; run scripts/make-release.sh $VERSION first" >&2; exit 1; }
SHA="$(awk '{print $1; exit}' "$SUM_FILE")"
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "$SUM_FILE does not hold a sha256" >&2; exit 1; }

sed -i '' -E \
    -e "s/^  version \"[^\"]*\"/  version \"$VERSION\"/" \
    -e "s/^  sha256 \"[^\"]*\"/  sha256 \"$SHA\"/" \
    "$CASK"
echo "→ $CASK is at Sirius $VERSION ($SHA)"
