#!/bin/zsh
# Puts Kore.app's tailnet helper (kore-tailnet, macOS arm64) at <dest>: executable, ad-hoc signed
# like the app, no quarantine. With Go it's built from this source (scripts/build-tailnet.sh).
# Without Go, or when that build fails, it's the release's kore-tailnet-macos-arm64, taken only
# when SHA256SUMS.sig verifies with the key compiled into Kore (Sources/KoreCore/ReleaseKey.swift,
# checked by scripts/sign/sign.swift) and the file matches its SHA-256 there. Anything short of
# that is one note and no helper (KoreNet then offers SSH only): it never fails the build.
#
#   scripts/tailnet-helper.sh <dest>
#
# KORE_RELEASES: the releases page (GitHub's by default). KORE_RELEASE_TAG: the release to take it
# from (install.sh's checked tag), else the latest.
set -uo pipefail

(( $# == 1 )) || { print -u2 "usage: scripts/tailnet-helper.sh <dest>"; exit 2; }
dest=${1:A}
cd "${0:A:h}/.."
NAME=kore-tailnet-macos-arm64
RELEASES="${KORE_RELEASES:-https://github.com/SoumilB7/kore/releases}"
rm -f "$dest"

put() { # file, what it is
    mkdir -p "${dest:h}" && cp "$1" "$dest" && chmod 755 "$dest" || return 1
    xattr -d com.apple.quarantine "$dest" 2>/dev/null
    codesign --force --options runtime --sign - "$dest" 2>/dev/null || { rm -f "$dest"; return 1; }
    print -r -- "kore-tailnet: $2"
}
note() { print -r -- "note: Kore.app ships without kore-tailnet ($1): KoreNet offers SSH only"; exit 0 }

# From source: a fresh build only, never an older one left in build/release.
built=build/release/$NAME
rm -f "$built"
scripts/build-tailnet.sh macos-arm64 || print "note: kore-tailnet didn't build from source: trying the release's"
if [[ -x $built ]]; then
    put "$built" "built from source" && exit 0
    note "couldn't sign the one built"
fi

# The release's.
key="$(sed -n 's/.*static let base64 = "\(.*\)"$/\1/p' Sources/KoreCore/ReleaseKey.swift)"
[[ -n $key && $key != PLACEHOLDER* ]] || note "no Go, and no release key in this source to check a download"
from="$RELEASES/latest/download"
[[ -z ${KORE_RELEASE_TAG:-} ]] || from="$RELEASES/download/$KORE_RELEASE_TAG"
tmp="$(mktemp -d -t kore-tailnet)"
trap 'rm -rf "$tmp"' EXIT
get() { curl -fsSL --connect-timeout 15 --max-time 600 -o "$tmp/$1" "$from/$1" 2>/dev/null }
get SHA256SUMS && get SHA256SUMS.sig || note "no Go, and no signed release to download it from"
swift scripts/sign/sign.swift verify "$tmp/SHA256SUMS" "$tmp/SHA256SUMS.sig" "$key" >/dev/null 2>&1 \
    || note "refused the release's: its SHA256SUMS isn't signed by Kore's release key"
read -r hash kore version commit < "$tmp/SHA256SUMS"
[[ "$hash $kore" == "# kore" && -n $version ]] || note "refused the release's: its SHA256SUMS isn't a Kore manifest"
want="$(sed -n "s/^\([0-9a-f]\{64\}\)  $NAME\$/\1/p" "$tmp/SHA256SUMS")"
[[ -n $want ]] || note "no Go, and release $version has no $NAME yet"
get $NAME || note "couldn't download release $version's $NAME"
[[ "$(shasum -a 256 "$tmp/$NAME" | cut -d' ' -f1)" == "$want" ]] \
    || note "refused release $version's $NAME: it doesn't match its signed SHA-256"
put "$tmp/$NAME" "release $version's, checked against its signed SHA256SUMS" || note "couldn't sign release $version's"
