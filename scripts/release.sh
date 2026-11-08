#!/bin/zsh
# Publishes v<VERSION> as Kore's ONE GitHub release: three install lines, this version's
# CHANGELOG.md highlights, and the files the installers and updates download, all listed in a
# signed SHA256SUMS. Once the new release is up, every other release and its tag is deleted, so
# the Releases page only ever shows the latest. Tags HEAD; commit first.
#
#   scripts/release.sh --prepare     build every file fresh for HEAD, sign SHA256SUMS with the
#                                    Keychain key, write notes.md, show the summary; publishes nothing
#   scripts/release.sh               publish what --prepare made (same commit, signature checked):
#                                    shows the summary, then asks on the terminal before anything
#                                    goes up, and again before older releases and tags are deleted
#   scripts/release.sh --dry-run     everything with a throwaway key; publishes nothing
#
# The files, each with one reader:
#   kore-src.tar.gz             this commit's source: install.sh builds Kore.app from it
#   kore-tailnet-macos-arm64    Kore.app's tailnet helper, for a Mac without Go (tailnet-helper.sh)
#   kore-host-linux-*.xz        kore-host for boxes (kore-host.sh, `kore-host update`, host.update)
#   kore-host.sh                the box install line
#   kore.apk                    the phone app, signed with the owner's keystore
#   SHA256SUMS, SHA256SUMS.sig  `# kore <version> <commit>`, every file's hash; Ed25519-signed.
#                               The header is the release's manifest: no other file is needed.
# They come from build/release/ (KORE_RELEASE_DIR for another folder) and are built when missing.
# SHA256SUMS is signed with the release key in the Keychain (scripts/sign/sign.swift); a dry run
# signs with a throwaway key, writes the notes to <dir>/notes.md and only says what it would
# publish. A dry run skips files it can't build (no Go, no keystore); a real run needs them all.
set -euo pipefail

cd "${0:A:h}/.."
DRY=""; PREPARE=""; PUBLISH=1
case "${1:-}" in
    --dry-run) DRY=1; PUBLISH="" ;;
    --prepare) PREPARE=1; PUBLISH="" ;;
    "") ;;
    *) print -u2 "usage: scripts/release.sh [--prepare | --dry-run]"; exit 2 ;;
esac
VERSION="$(<VERSION)"
TAG="v$VERSION"
REPO=SoumilB7/kore
RAW="https://raw.githubusercontent.com/$REPO/main"
DOWNLOAD="https://github.com/$REPO/releases/latest/download"
OUT="${KORE_RELEASE_DIR:-build/release}"
KEY="$(sed -n 's/.*static let base64 = "\(.*\)"$/\1/p' Sources/KoreCore/ReleaseKey.swift)"
# The certificate every kore.apk is signed with (its SHA-256), as the phone pins it.
SIGNER="$(sed -n 's/.*const val RELEASE_SIGNER = "\(.*\)"$/\1/p' android/link/src/main/kotlin/dev/kore/link/update/Release.kt)"

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
[[ $SIGNER =~ '^([0-9A-F]{2}:){31}[0-9A-F]{2}$' ]] || { print -u2 "Release.kt has no RELEASE_SIGNER"; exit 1; }

section=$(awk -v v="$VERSION" '
  /^## \[/ { on = index($0, "[" v "]") > 0; next }
  /^\[[0-9.]+\]:/ { next }
  on' CHANGELOG.md)
[[ -n ${section//[[:space:]]/} ]] || { print -u2 "no CHANGELOG.md section for $VERSION"; exit 1; }
# What's new: the section's first six bullets, each to the end of its first sentence.
highlights=$(print -r -- "$section" | awk '
  /^- / { if (b != "") list[n++] = b; b = substr($0, 3); next }
  /^  +[^ ]/ && b != "" { sub(/^ +/, ""); b = b " " $0; next }
  { if (b != "") list[n++] = b; b = "" }
  END {
    if (b != "") list[n++] = b
    for (i = 0; i < n && i < 6; i++) {
      s = list[i]; cut = index(s, ". "); if (cut) s = substr(s, 1, cut)
      sub(/\.$/, "", s); print "- " s
    }
  }')

# Publishing takes only what --prepare made for this very commit, signed with the release key.
if [[ -n $PUBLISH ]]; then
    [[ -f "$OUT/SHA256SUMS" && -f "$OUT/SHA256SUMS.sig" ]] || { print -u2 "nothing prepared in $OUT: scripts/release.sh --prepare"; exit 1; }
    head="$(head -1 "$OUT/SHA256SUMS")"
    [[ $head == "# kore $VERSION $(git rev-parse HEAD)" ]] || { print -u2 "$OUT was prepared for another commit or version ($head): --prepare again"; exit 1; }
    swift scripts/sign/sign.swift verify "$OUT/SHA256SUMS" "$OUT/SHA256SUMS.sig" "$KEY" >/dev/null || { print -u2 "SHA256SUMS.sig doesn't check out"; exit 1; }
    (cd "$OUT" && shasum -a 256 -c <(tail -n +2 SHA256SUMS) >/dev/null) || { print -u2 "a prepared file changed since it was signed"; exit 1; }
fi

# The files: a real build starts from an empty folder, so nothing older slips in.
[[ -n $PREPARE ]] && rm -rf "$OUT"
mkdir -p "$OUT"
built() { # build/release's copy into OUT, when OUT is another folder
    if [[ -f "build/release/$1" && ! "$OUT" -ef build/release ]]; then cp "build/release/$1" "$OUT/"; fi
}
if [[ -z $PUBLISH ]]; then
# A dry run may build fewer (KORE_HOST_ARCHS="x86_64"); a real run needs both.
for arch in ${=${KORE_HOST_ARCHS:-x86_64 aarch64}}; do
    [[ -f "$OUT/kore-host-linux-$arch.xz" ]] || { scripts/build-host.sh $arch; built kore-host-linux-$arch.xz; }
done
[[ -f "$OUT/kore-tailnet-macos-arm64" ]] || { scripts/build-tailnet.sh macos-arm64; built kore-tailnet-macos-arm64; }
# The phone app, signed with the owner's keystore (a dry run leaves it out: no Keychain).
[[ -f "$OUT/kore.apk" || -n $DRY ]] || android/scripts/sign-release.sh "$OUT"
if [[ -f "$OUT/kore.apk" ]]; then
    apksigner=(${ANDROID_HOME:-$HOME/Library/Android/sdk}/build-tools/*/apksigner(N[-1]))
    got=$("${apksigner[1]:-apksigner}" verify --print-certs "$OUT/kore.apk" | sed -n 's/.*SHA-256 digest: //p' | head -1 | tr a-f A-F | sed 's/../&:/g; s/:$//')
    [[ $got == $SIGNER ]] || { print -u2 "kore.apk isn't signed with the release certificate (${got:-no signer})"; exit 1; }
fi
cp scripts/kore-host.sh "$OUT/kore-host.sh"
git archive --format=tar.gz --prefix=kore/ -o "$OUT/kore-src.tar.gz" HEAD
assets=()
for name in kore-src.tar.gz kore-tailnet-macos-arm64 kore-host-linux-x86_64.xz kore-host-linux-aarch64.xz kore-host.sh kore.apk; do
    if [[ -f "$OUT/$name" ]]; then assets+=($name)
    elif [[ -n $DRY ]]; then print "skipped $name (not built)"
    else print -u2 "$name wasn't built: nothing published"; exit 1; fi
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
else
    # Publishing: the files are the ones SHA256SUMS lists (checked above).
    assets=($(tail -n +2 "$OUT/SHA256SUMS" | awk '{print $2}'))
fi
files=("$OUT/SHA256SUMS" "$OUT/SHA256SUMS.sig" "${assets[@]/#/$OUT/}")

title="Kore $VERSION"
notes="**Mac** · Apple silicon, macOS 15+
\`\`\`
curl -fsSL $RAW/install.sh | bash
\`\`\`
**Linux box** · x86_64 or aarch64
\`\`\`
curl -fsSL $DOWNLOAD/kore-host.sh | sh
\`\`\`
**Android phone** · Android 12+ · [kore.apk]($DOWNLOAD/kore.apk)

### What's new
$highlights

[Full changelog](https://github.com/$REPO/blob/$TAG/CHANGELOG.md)

<sub>Every file is in SHA256SUMS, signed with Kore's Ed25519 release key \`$KEY\`; the installers and updates check it before anything runs. kore.apk signer SHA-256 \`$SIGNER\`.</sub>"

print -r -- "# $title"$'\n\n'"$notes" > "$OUT/notes.md"
older=($(gh release list --limit 200 --json tagName --jq '.[].tagName' 2>/dev/null | grep -vx "$TAG" || true))
oldtags=($(git ls-remote --tags --refs origin 'v*' 2>/dev/null | sed 's|.*refs/tags/||' | grep -vx "$TAG" || true))
print "\n$title ($(git rev-parse --short HEAD)) as the latest release of github.com/$REPO, with:"
for f in $files; do printf '  %-28s %8d KB\n' "${f:t}" $(( ($(stat -f %z "$f") + 1023) / 1024 )); done
print "notes: $OUT/notes.md"
print "already there: releases ${older[*]:-none}; tags ${oldtags[*]:-none}"
if [[ -n $DRY ]]; then
    print "\ndry run (throwaway key $KEY): nothing published"
    exit 0
fi
if [[ -n $PREPARE ]]; then
    print "\nprepared and signed. To publish: scripts/release.sh (it asks first)"
    exit 0
fi

# The owner says yes on the terminal, never a pipe or a flag.
[[ -r /dev/tty ]] || { print -u2 "publishing asks on a terminal: run it in Terminal"; exit 1; }
print -n "\nPublish $title now? [y/N] " > /dev/tty; read -r answer < /dev/tty
[[ $answer == [yY] ]] || { print "not published"; exit 1; }
drop=""
if (( ${#older} + ${#oldtags} )); then
    print -n "Then delete releases ${older[*]:-none} and tags ${oldtags[*]:-none}, so only $TAG shows? [y/N] " > /dev/tty
    read -r answer < /dev/tty; [[ $answer == [yY] ]] && drop=1
fi

# The tag is the repo owner's, whatever the local git identity is, and dated like the commit.
GIT_COMMITTER_NAME=SoumilB7 GIT_COMMITTER_EMAIL=107888098+SoumilB7@users.noreply.github.com \
  GIT_COMMITTER_DATE="$(git log -1 --format=%cI)" git tag -a "$TAG" -m "$title"
git -c credential.helper= -c credential.helper='!gh auth git-credential' push --quiet origin "$TAG"
gh release create "$TAG" --verify-tag --title "$title" --notes "$notes" --latest $files

# Only once the new one is up with every file: every other release and tag goes.
up=$(gh release view "$TAG" --json assets --jq '.assets | length')
(( up == ${#files} )) || { print -u2 "$TAG is up with $up of ${#files} files: older releases kept"; exit 1; }
# This Mac offers the release's phone app to linked phones (the Mac-copy update), only once the
# release is up: a prepared but unpublished build is never offered.
phone="$HOME/Library/Application Support/Kore/phone-app"
mkdir -p "$phone" && cp "$OUT/SHA256SUMS" "$OUT/SHA256SUMS.sig" "$OUT/kore.apk" "$phone/"
[[ -n $drop ]] || { echo "published $TAG; older releases and tags kept"; exit 0; }
for old in $(gh release list --limit 200 --json tagName --jq '.[].tagName'); do
    [[ "$old" == "$TAG" ]] && continue
    gh release delete "$old" --cleanup-tag --yes
    git tag -d "$old" >/dev/null 2>&1 || true
    echo "removed $old"
done
# Tags left from releases deleted by hand go too: the tags page shows only this one.
for old in $(git ls-remote --tags --refs origin 'v*' | sed 's|.*refs/tags/||'); do
    [[ "$old" == "$TAG" ]] && continue
    git -c credential.helper= -c credential.helper='!gh auth git-credential' push --quiet origin ":refs/tags/$old"
    git tag -d "$old" >/dev/null 2>&1 || true
    echo "removed tag $old"
done
echo "published $TAG, the only release"
