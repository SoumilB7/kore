#!/bin/zsh
# Publishes build/Kore-<version>.dmg as the GitHub release v<version>, with that version's
# CHANGELOG.md section as its notes. Tags HEAD; run scripts/make-dmg.sh on the same commit first.
#
#   scripts/release.sh [--draft]
set -euo pipefail

cd "${0:A:h}/.."
VERSION="$(<VERSION)"
TAG="v$VERSION"
DMG="build/Kore-$VERSION.dmg"

[[ -f $DMG && -f $DMG.sha256 ]] || { print -u2 "no $DMG: run scripts/make-dmg.sh"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { print -u2 "uncommitted changes: commit first"; exit 1; }
built=$(/usr/libexec/PlistBuddy -c 'Print :KoreBuild' build/Kore.app/Contents/Info.plist)
[[ $built == $(git rev-parse --short HEAD) ]] || { print -u2 "$DMG is from $built, not HEAD: rebuild"; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { print -u2 "$TAG already exists"; exit 1; }

# The notes: this version's section, without its heading.
notes=$(awk -v v="$VERSION" '
  /^## \[/ { on = index($0, "[" v "]") > 0; next }
  /^\[[0-9.]+\]:/ { next }
  on' CHANGELOG.md)
[[ -n ${notes//[[:space:]]/} ]] || { print -u2 "no CHANGELOG.md section for $VERSION"; exit 1; }

# The tag is the repo owner's, whatever the local git identity is, and dated like the commit.
GIT_COMMITTER_NAME=SoumilB7 GIT_COMMITTER_EMAIL=107888098+SoumilB7@users.noreply.github.com \
  GIT_COMMITTER_DATE="$(git log -1 --format=%cI)" git tag -a "$TAG" -m "Kore $VERSION"
git -c credential.helper= -c credential.helper='!gh auth git-credential' push origin "$TAG"
gh release create "$TAG" "$DMG" "$DMG.sha256" --verify-tag --title "Kore $VERSION" \
  --notes "$notes" ${1:+"$1"}
