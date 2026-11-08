#!/bin/zsh
# Publishes v<VERSION> as Kore's ONE GitHub release: the install command, this version's
# CHANGELOG.md section, and the files boxes download, all listed in a signed SHA256SUMS. Once
# the new release is up, every other release and its tag is deleted, so the Releases page only
# ever shows the latest. Tags HEAD; commit first.
#
#   scripts/release.sh [--dry-run]
#
# Assets come from build/release/ (KORE_RELEASE_DIR for another folder): kore-host-linux-*.xz
# (built by build-host.sh when missing), kore-host.sh, kore-src.tar.gz (this commit's source,
# which install.sh builds), and kore-tailnet-* / kore.apk when they're there. SHA256SUMS is
# signed with the release key in the Keychain (scripts/sign/sign.swift); a dry run signs with a
# throwaway key and only says what it would publish.
set -euo pipefail

cd "${0:A:h}/.."
DRY=""; [[ "${1:-}" == --dry-run ]] && DRY=1
VERSION="$(<VERSION)"
TAG="v$VERSION"
RAW="https://raw.githubusercontent.com/SoumilB7/kore/main"
DOWNLOAD="https://github.com/SoumilB7/kore/releases/latest/download"
OUT="${KORE_RELEASE_DIR:-build/release}"
KEY="$(sed -n 's/.*static let base64 = "\(.*\)"$/\1/p' Sources/KoreCore/ReleaseKey.swift)"

if [[ -n "$(git status --porcelain)" ]]; then
    [[ -n $DRY ]] || { print -u2 "uncommitted changes: commit first"; exit 1; }
    print "(dry run: there are uncommitted changes)"
fi
[[ -n $DRY ]] || git fetch --quiet --tags origin
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    [[ -n $DRY ]] || { print -u2 "$TAG already exists"; exit 1; }
    print "(dry run: $TAG exists already: bump VERSION first)"
fi
if [[ -z $KEY || $KEY == PLACEHOLDER* ]]; then
    [[ -n $DRY ]] || { print -u2 "KoreReleaseKey is still the placeholder: swift scripts/sign/sign.swift --new-key"; exit 1; }
    print "(dry run: KoreReleaseKey is still the placeholder)"
fi
for file in scripts/kore-host.sh install.sh; do
    grep -qF "KORE_RELEASE_KEY=\"$KEY\"" $file || { print -u2 "$file doesn't carry KoreReleaseKey"; exit 1; }
done

section=$(awk -v v="$VERSION" '
  /^## \[/ { on = index($0, "[" v "]") > 0; next }
  /^\[[0-9.]+\]:/ { next }
  on' CHANGELOG.md)
[[ -n ${section//[[:space:]]/} ]] || { print -u2 "no CHANGELOG.md section for $VERSION"; exit 1; }

# The files.
mkdir -p "$OUT"
for arch in x86_64 aarch64; do
    [[ -f "$OUT/kore-host-linux-$arch.xz" ]] && continue
    scripts/build-host.sh $arch
    [[ "$OUT" -ef build/release ]] || cp "build/release/kore-host-linux-$arch.xz" "$OUT/"
done
cp scripts/kore-host.sh "$OUT/kore-host.sh"
git archive --format=tar.gz --prefix=kore/ -o "$OUT/kore-src.tar.gz" HEAD
assets=(kore-host-linux-x86_64.xz kore-host-linux-aarch64.xz kore-host.sh kore-src.tar.gz)
for optional in kore-tailnet-linux-x86_64 kore-tailnet-linux-aarch64 kore-tailnet-macos-arm64 kore.apk; do
    if [[ -f "$OUT/$optional" ]]; then assets+=($optional); else print "skipped $optional (not built)"; fi
done

# SHA256SUMS: `# kore <version> <commit>`, then the files by name; signed whole.
{
    print -r -- "# kore $VERSION $(git rev-parse HEAD)"
    for name in ${(o)assets}; do print -r -- "$(shasum -a 256 "$OUT/$name" | cut -d' ' -f1)  $name"; done
} > "$OUT/SHA256SUMS"
if [[ -n $DRY ]]; then
    KEY="$(swift scripts/sign/sign.swift sign --ephemeral "$OUT/SHA256SUMS")"
else
    swift scripts/sign/sign.swift sign "$OUT/SHA256SUMS" --expect "$KEY"
fi
swift scripts/sign/sign.swift verify "$OUT/SHA256SUMS" "$OUT/SHA256SUMS.sig" "$KEY" >/dev/null
files=("$OUT/SHA256SUMS" "$OUT/SHA256SUMS.sig" "${assets[@]/#/$OUT/}")

notes="Install or update by pasting one line into Terminal. It builds Kore on your Mac and opens it. Run it again to update.

\`\`\`
curl -fsSL $RAW/install.sh | bash
\`\`\`

Needs an Apple silicon Mac on macOS 15+.

kore-host on a Linux box (x86_64 or aarch64):

\`\`\`
curl -fsSL $DOWNLOAD/kore-host.sh | sh
\`\`\`

Every file here is listed in SHA256SUMS, signed with Kore's release key (SHA256SUMS.sig, Ed25519): \`$KEY\`

## What's new in $VERSION
$section"

if [[ -n $DRY ]]; then
    print "\ndry run: would publish $TAG ($(git rev-parse --short HEAD)) as the latest release with:"
    for f in $files; do printf '  %-28s %8d KB\n' "${f:t}" $(( ($(stat -f %z "$f") + 1023) / 1024 )); done
    print "\nSHA256SUMS:"; sed 's/^/  /' "$OUT/SHA256SUMS"
    print "\nthen: tag $TAG and push it; gh release create $TAG --latest with those ${#files} files;"
    print "check it's up with all ${#files}; only then delete every other release and its tag."
    exit 0
fi

# The tag is the repo owner's, whatever the local git identity is, and dated like the commit.
GIT_COMMITTER_NAME=SoumilB7 GIT_COMMITTER_EMAIL=107888098+SoumilB7@users.noreply.github.com \
  GIT_COMMITTER_DATE="$(git log -1 --format=%cI)" git tag -a "$TAG" -m "Kore $VERSION"
git -c credential.helper= -c credential.helper='!gh auth git-credential' push --quiet origin "$TAG"
gh release create "$TAG" --verify-tag --title "Kore $VERSION" --notes "$notes" --latest $files

# Only once the new one is up with every file: every other release and its tag go.
up=$(gh release view "$TAG" --json assets --jq '.assets | length')
(( up == ${#files} )) || { print -u2 "$TAG is up with $up of ${#files} files: older releases kept"; exit 1; }
for old in $(gh release list --limit 200 --json tagName --jq '.[].tagName'); do
    [[ "$old" == "$TAG" ]] && continue
    gh release delete "$old" --cleanup-tag --yes
    git tag -d "$old" >/dev/null 2>&1 || true
    echo "removed $old"
done
echo "published $TAG, the only release"
