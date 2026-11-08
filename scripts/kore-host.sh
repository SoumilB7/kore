#!/bin/sh
# kore-host on a Linux box, from Kore's latest release:
#   curl -fsSL https://github.com/SoumilB7/kore/releases/latest/download/kore-host.sh | sh
# Downloads this machine's kore-host, checks it against the release's SHA256SUMS and that file's
# signature (Kore's release key, below), puts it in ~/.local/bin and starts its service. This
# script is listed in SHA256SUMS too. Run it again to update.
set -eu

# Kore's release key (Ed25519, raw 32 bytes, base64): the same as KoreReleaseKey in Kore.app.
KORE_RELEASE_KEY="PLACEHOLDER-run-scripts/sign/sign.swift--new-key"
BASE="${KORE_RELEASE_URL:-https://github.com/SoumilB7/kore/releases/latest/download}"
BIN="$HOME/.local/bin"

say() { printf '%s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
    Linux) ;;
    *) fail "this installs kore-host on Linux; on a Mac, Kore sets up kore-host itself" ;;
esac
case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) fail "no kore-host for $(uname -m): x86_64 and aarch64 only" ;;
esac
case "$KORE_RELEASE_KEY" in
    PLACEHOLDER*) fail "this script has no release key yet, so nothing it downloads can be checked" ;;
esac
command -v curl >/dev/null 2>&1 || fail "needs curl"
command -v xz >/dev/null 2>&1 || fail "needs xz (apt install xz-utils, dnf install xz)"
if command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
else fail "needs sha256sum"; fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
asset="kore-host-linux-$arch.xz"
say "▸ Downloading kore-host for linux-$arch…"
for name in SHA256SUMS SHA256SUMS.sig "$asset"; do
    curl -fsSL --retry 2 -o "$tmp/$name" "$BASE/$name" || fail "couldn't download $name from $BASE"
done

# The signature, with OpenSSL 3's Ed25519 when this box has it. The key's PEM is the fixed
# 12-byte Ed25519 SubjectPublicKeyInfo prefix (base64 MCowBQYDK2VwAyEA) and the raw key.
signed=""
if command -v openssl >/dev/null 2>&1 && openssl pkeyutl -help 2>&1 | grep -q rawin; then
    printf -- '-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEA%s\n-----END PUBLIC KEY-----\n' "$KORE_RELEASE_KEY" > "$tmp/key.pem"
    openssl pkeyutl -verify -pubin -inkey "$tmp/key.pem" -rawin -in "$tmp/SHA256SUMS" -sigfile "$tmp/SHA256SUMS.sig" >/dev/null 2>&1 \
        || fail "SHA256SUMS isn't signed by Kore's release key: nothing installed"
    signed=yes
fi

want="$(sed -n "s/^\([0-9a-f]\{64\}\)  $asset\$/\1/p" "$tmp/SHA256SUMS")"
[ -n "$want" ] || fail "SHA256SUMS doesn't list $asset"
[ "$(sha "$tmp/$asset")" = "$want" ] || fail "$asset doesn't match SHA256SUMS: nothing installed"
version="$(sed -n '1s/^# kore \([0-9.]*\) [0-9a-f]*$/\1/p' "$tmp/SHA256SUMS")"
[ -n "$version" ] || fail "SHA256SUMS has no version line"

xz -dc "$tmp/$asset" > "$tmp/kore-host" || fail "couldn't unpack $asset"
chmod 755 "$tmp/kore-host"
case "$("$tmp/kore-host" --version 2>/dev/null)" in
    "kore-host $version "*) ;;
    *) fail "that kore-host doesn't run here, or isn't $version" ;;
esac
if [ -z "$signed" ]; then
    # No Ed25519 in this openssl: an installed kore-host checks the signature (it carries the
    # key); on a first install only the new one can, which catches a damaged download, not a forged one.
    # An installed one says 1 for a bad signature, 2 when it's too old to know `verify`.
    old=2
    [ ! -x "$BIN/kore-host" ] || { "$BIN/kore-host" verify "$tmp/SHA256SUMS" >/dev/null 2>&1 && old=0 || old=$?; }
    if [ "$old" = 0 ]; then
        say "  (signature checked by the installed kore-host: this openssl can't check Ed25519)"
    elif [ "$old" = 1 ]; then
        fail "SHA256SUMS isn't signed by Kore's release key: nothing installed"
    else
        say "  (this openssl can't check Ed25519: the new kore-host checks the signature itself)"
        "$tmp/kore-host" verify "$tmp/SHA256SUMS" >/dev/null || fail "SHA256SUMS isn't signed by Kore's release key: nothing installed"
    fi
fi

mkdir -p "$BIN"
mv -f "$tmp/kore-host" "$BIN/.kore-host.new"
mv -f "$BIN/.kore-host.new" "$BIN/kore-host"
say "▸ Installed kore-host $version in $BIN"
"$BIN/kore-host" install-service || fail "kore-host is installed but its service didn't start (see above)"
case ":$PATH:" in
    *":$BIN:"*) ;;
    *) say "  $BIN isn't on your PATH: add it, or run $BIN/kore-host" ;;
esac
say ""
say "Next: kore-host join"
