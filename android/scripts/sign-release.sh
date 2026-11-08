#!/bin/zsh
# The release APK: an unsigned assembleRelease, zipaligned to 16 KB, then signed (v2 + v3) with the
# owner's keystore at ~/Library/Android/keys/kore-release.jks (alias kore). The keystore password
# comes from the login Keychain (generic password `kore-android-keystore`) and is handed to
# apksigner through an environment variable, never an argument, file or log. Writes
# <out>/kore.apk (default ../build/release) and prints the signer certificate's SHA-256, the value
# docs/android.md publishes.
#
#   android/scripts/sign-release.sh [out-dir]
set -euo pipefail
here=${0:A:h}
export KORE_ANDROID=${here:h}
source "$here/env.sh"
out=${1:-${KORE_ANDROID:h}/build/release}
store=${KORE_KEYSTORE:-$ANDROID_ROOT/keys/kore-release.jks}
tools="$ANDROID_HOME/build-tools/36.0.0"

[[ -f $store ]] || { print -u2 "no keystore at $store"; exit 2 }
KORE_STORE_PASS=$(security find-generic-password -s kore-android-keystore -w 2>/dev/null) \
    || { print -u2 "no kore-android-keystore password in the Keychain"; exit 2 }
export KORE_STORE_PASS

kore_gradle --offline --no-daemon --quiet :app:assembleRelease
unsigned="$KORE_ANDROID/app/build/outputs/apk/release/app-release-unsigned.apk"
mkdir -p "$out"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
"$tools/zipalign" -f -P 16 4 "$unsigned" "$tmp/aligned.apk"
"$tools/apksigner" sign --ks "$store" --ks-key-alias kore --ks-pass env:KORE_STORE_PASS \
    --v2-signing-enabled true --v3-signing-enabled true --out "$out/kore.apk" "$tmp/aligned.apk"
"$tools/apksigner" verify --print-certs "$out/kore.apk" | grep -m1 'SHA-256 digest' | sed 's/.*digest: /signer sha256 /'
print "kore.apk $(( $(stat -f %z "$out/kore.apk") / 1048576 )) MB -> $out/kore.apk"
