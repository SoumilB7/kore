#!/bin/bash
# Install or update Kore:
#   curl -fsSL https://raw.githubusercontent.com/SoumilB7/kore/main/install.sh | bash
# The latest release, or the one named (`… | bash -s -- v0.3.0`, as Kore's update does). Run it
# again to update.
#
# Builds Kore on this Mac, so there's no unsigned download for macOS to block, puts it in
# /Applications and links the `kore` command. A release with SHA256SUMS.sig is built from its
# source tarball, checked against that signature (Kore's release key, below) first; one without
# is built from git as before. An older version than the installed one is refused (KORE_FORCE=1
# installs it anyway).
set -euo pipefail

# Kore's release key (Ed25519, raw 32 bytes, base64): the same as KoreReleaseKey in Kore.app.
KORE_RELEASE_KEY="PLACEHOLDER-run-scripts/sign/sign.swift--new-key"
REPO="${KORE_REPO:-https://github.com/SoumilB7/kore.git}"
RELEASES="${KORE_RELEASES:-https://github.com/SoumilB7/kore/releases}"
DIR="${KORE_DIR:-$HOME/.kore/Kore}"
APP="${KORE_APP:-/Applications/Kore.app}"
TAG="${1:-}"
[[ -z "$TAG" || "$TAG" =~ ^v[0-9]+(\.[0-9]+)*$ ]] || { printf "✗ %s isn't a release tag (v0.3.0)\n" "$TAG" >&2; exit 1; }

step() { printf "\n▸ %s\n" "$1"; }
fail() { printf "\n✗ %s\n" "$1" >&2; exit 1; }

[[ "$(uname -m)" == arm64 ]] || fail "Kore needs an Apple silicon Mac."
(( $(sw_vers -productVersion | cut -d. -f1) >= 15 )) || fail "Kore needs macOS 15 or later."

if ! xcode-select -p >/dev/null 2>&1; then
    step "Installing Apple's Command Line Tools: accept the dialog (one time, ~10 min)…"
    xcode-select --install >/dev/null 2>&1 || true
    waited=0
    until xcode-select -p >/dev/null 2>&1; do
        (( waited < 1800 )) || fail "The Command Line Tools still aren't installed after 30 min. Run: xcode-select --install, then this command again."
        sleep 10; waited=$((waited + 10))
        (( waited % 60 != 0 )) || echo "  …waiting for the Command Line Tools ($((waited / 60)) min)"
    done
fi

# Package.swift's swift-tools-version, asked before any download.
swift_version="$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p' | head -n 1)"
read -r swift_major swift_minor <<<"${swift_version:-0 0}"
(( swift_major > 6 || (swift_major == 6 && swift_minor >= 2) )) \
    || fail "Kore needs Swift 6.2 or later. Update the Command Line Tools in System Settings → Software Update, then run this again."

free_kb="$(df -Pk "$HOME" | awk 'NR == 2 { print $4 }')"
(( free_kb >= 4 * 1024 * 1024 )) || fail "Kore needs about 4 GB free to build; this Mac has $(( free_kb / 1024 / 1024 )) GB."

# "0.10.0" is newer than "0.9.3"; a missing part counts as 0.
newer() {
    local IFS=. i a b
    read -ra a <<<"$1"; read -ra b <<<"$2"
    for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
        (( 10#${a[i]:-0} == 10#${b[i]:-0} )) || { (( 10#${a[i]:-0} > 10#${b[i]:-0} )); return; }
    done
    return 1
}
# Refuses a version older than the installed Kore.
not_older() {
    local installed
    installed="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
    if [[ -n "$installed" && -z "${KORE_FORCE:-}" ]] && newer "$installed" "$1"; then
        fail "Kore $installed is installed, newer than $1: nothing changed (KORE_FORCE=1 installs $1 anyway)."
    fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# No tag: the latest release's, from where GitHub's /releases/latest leads.
if [[ -z "$TAG" ]]; then
    latest="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$RELEASES/latest" 2>/dev/null || true)"
    [[ "${latest##*/}" =~ ^v[0-9]+(\.[0-9]+)*$ ]] && TAG="${latest##*/}"
fi
signed=""
if [[ -n "$TAG" && "$KORE_RELEASE_KEY" != PLACEHOLDER* ]] \
   && curl -fsSL -o "$tmp/SHA256SUMS" "$RELEASES/download/$TAG/SHA256SUMS" 2>/dev/null \
   && curl -fsSL -o "$tmp/SHA256SUMS.sig" "$RELEASES/download/$TAG/SHA256SUMS.sig" 2>/dev/null; then
    signed=1
fi
if [[ -n "$signed" ]]; then
    step "Checking Kore ${TAG#v}…"
    # Ed25519 with CryptoKit: this Mac's openssl (LibreSSL) has none.
    cat > "$tmp/verify.swift" <<'SWIFT'
import CryptoKit
import Foundation
let a = CommandLine.arguments, read = { FileManager.default.contents(atPath: $0) ?? Data() }
let key = try? Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: a[3]) ?? Data())
exit(key?.isValidSignature(read(a[2]), for: read(a[1])) == true ? 0 : 1)
SWIFT
    swift "$tmp/verify.swift" "$tmp/SHA256SUMS" "$tmp/SHA256SUMS.sig" "$KORE_RELEASE_KEY" \
        || fail "$TAG's SHA256SUMS isn't signed by Kore's release key: nothing changed."
    read -r hash kore version commit < "$tmp/SHA256SUMS"
    [[ "$hash $kore" == "# kore" && "v$version" == "$TAG" && "$commit" =~ ^[0-9a-f]{40}$ ]] \
        || fail "$TAG's SHA256SUMS is for another release: nothing changed."
    not_older "$version"
    want="$(sed -n 's/^\([0-9a-f]\{64\}\)  kore-src\.tar\.gz$/\1/p' "$tmp/SHA256SUMS")"
    step "Downloading Kore $version…"
    curl -fsSL -o "$tmp/kore-src.tar.gz" "$RELEASES/download/$TAG/kore-src.tar.gz" \
        || fail "Couldn't download Kore. Check your connection and try again."
    [[ -n "$want" && "$(shasum -a 256 "$tmp/kore-src.tar.gz" | cut -d' ' -f1)" == "$want" ]] \
        || fail "The download doesn't match $TAG's signed SHA256SUMS: nothing changed."
    # The source in place of the old, its build cache kept so the next build is quick.
    rm -rf "$DIR.new"
    mkdir -p "$DIR.new"
    tar -xzf "$tmp/kore-src.tar.gz" -C "$DIR.new" --strip-components 1 || fail "Couldn't unpack Kore's source."
    [[ ! -d "$DIR/.build" ]] || mv "$DIR/.build" "$DIR.new/.build"
    rm -rf "$DIR"
    mv "$DIR.new" "$DIR"
    export KORE_BUILD_SHA="${commit:0:7}" KORE_SOURCE_COMMIT="$commit"
else
    # One note when a release was named or found but can't be checked.
    if [[ "$KORE_RELEASE_KEY" == PLACEHOLDER* ]]; then
        printf "  (no release key in this installer yet: building the latest Kore from git)\n"
    elif [[ -n "$TAG" ]]; then
        printf "  (%s has no signature: building the latest Kore from git)\n" "$TAG"
    fi
    # The clone is this script's, not a working copy: an update resets it to origin/main, and its
    # build cache stays so the next build is quick. A broken one is moved aside and cloned fresh.
    aside=""
    [[ ! -d "$DIR/.git" ]] || step "Updating Kore…"
    if [[ -d "$DIR/.git" ]] && git -C "$DIR" rev-parse -q --verify HEAD >/dev/null 2>&1 \
       && git -C "$DIR" fetch --quiet origin 2>/dev/null; then
        git -C "$DIR" checkout --quiet --force -B main origin/main
    else
        if [[ -e "$DIR" ]]; then
            aside="$DIR.old-$(date +%Y%m%d-%H%M%S)"
            mv "$DIR" "$aside"
            echo "  (the copy in $DIR looked incomplete, moved to $aside)"
        fi
        step "Downloading Kore…"
        mkdir -p "$(dirname "$DIR")"
        if ! git clone --quiet "$REPO" "$DIR"; then
            rm -rf "$DIR"
            [[ -z "$aside" ]] || mv "$aside" "$DIR"
            fail "Couldn't download Kore. Check your connection and try again."
        fi
    fi
    not_older "$(<"$DIR/VERSION")"
fi

[[ -z "${KORE_NO_BUILD:-}" ]] || { echo "Kore's source is ready in $DIR (KORE_NO_BUILD: not built)"; exit 0; }
step "Building and installing Kore (first time ~5–10 min)…"
# Installing quits a running Kore (it asks first if chats are working). Run from Kore's own
# terminal, that closes this one: the install goes on, through tee, with nowhere left to print.
trap '' HUP
set +eo pipefail
( cd "$DIR" && ./scripts/build-app.sh --install ) 2>&1 | tee "$DIR/install.log"
status=${PIPESTATUS[0]}
set -eo pipefail
(( status == 0 )) || fail "Kore didn't install (see $DIR/install.log). Nothing was changed if it's still running."

[[ -n "${KORE_NO_OPEN:-}" ]] || open /Applications/Kore.app
cat <<DONE

✅ Kore is installed. Update any time with \`kore update\`, or by running this command again.
DONE
