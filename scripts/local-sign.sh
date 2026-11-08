#!/bin/zsh
# This Mac's own code-signing identity for Kore builds, made once: a self-signed certificate
# "Kore Local Signing" (10 years, codeSigning) with its key in the login keychain, usable by
# /usr/bin/codesign. Signing every build with it keeps Kore the same app to macOS across updates
# (designated requirement `identifier dev.kore.Kore and certificate leaf = H"…"`), so the
# Keychain's Always Allow and privacy permissions hold; an ad-hoc build is a new app each time.
# The key never leaves this Mac. codesign signs with it untrusted, so no trust setting and no
# admin prompt; the first build asks once to let codesign use the key (Always Allow).
#
# Prints the identity's name, or nothing when it can't be had; always exits 0, so an install
# goes on ad-hoc rather than failing. install.sh hands the name to build-app.sh.
#
#   KORE_SIGN_NAME      the certificate's name (default "Kore Local Signing")
#   KORE_SIGN_KEYCHAIN  the keychain (default the login keychain; tests use a scratch one)
NAME="${KORE_SIGN_NAME:-Kore Local Signing}"
KC="${KORE_SIGN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
# macOS's own openssl: a Homebrew OpenSSL 3 writes .p12 files `security import` can't read.
SSL=/usr/bin/openssl

has() { security find-identity -p codesigning "$KC" 2>/dev/null | grep -qF "\"$NAME\"" }

if ! has; then
    [[ -f $KC ]] || exit 0
    tmp=$(mktemp -d 2>/dev/null) || exit 0
    trap 'rm -rf "$tmp"' EXIT
    print -r -- "[req]
distinguished_name = dn
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning" > "$tmp/cfg"
    pass=$($SSL rand -hex 16 2>/dev/null) || exit 0
    $SSL req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cfg" -extensions ext \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1 || exit 0
    $SSL pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$NAME" \
        -out "$tmp/id.p12" -passout "pass:$pass" >/dev/null 2>&1 || exit 0
    security import "$tmp/id.p12" -k "$KC" -P "$pass" -T /usr/bin/codesign >/dev/null 2>&1 || exit 0
    has || exit 0
fi
print -r -- "$NAME"
