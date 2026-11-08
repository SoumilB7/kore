#!/bin/zsh
# scripts/local-sign.sh in a scratch keychain (never the login one): it makes the identity once,
# finds it after, and two different builds signed with it keep one designated requirement (the
# certificate's), where ad-hoc builds each get their own (their cdhash). Failure leaves it ad-hoc.
cd "${0:A:h}/../.."
tmp=$(mktemp -d)
kc=$tmp/sign.keychain-db
pw=scratch-$RANDOM
fails=0
check() { if eval "$2"; then print "✔ $1"; else print "✘ $1"; fails=$((fails + 1)); fi }
cleanup() { security delete-keychain "$kc" >/dev/null 2>&1; rm -rf "$tmp" }
trap cleanup EXIT

security create-keychain -p "$pw" "$kc"
security unlock-keychain -p "$pw" "$kc"
security set-keychain-settings "$kc"   # no auto-lock while the test runs

name="Kore Sign Test $RANDOM"
first=$(KORE_SIGN_KEYCHAIN=$kc KORE_SIGN_NAME=$name scripts/local-sign.sh); code=$?
check "makes the identity and prints its name" '(( code == 0 )) && [[ $first == $name ]]'
count() { security find-identity -p codesigning "$kc" | grep -cF "\"$name\"" }
check "  one codesigning identity, untrusted is fine" '(( $(count) == 1 ))'
again=$(KORE_SIGN_KEYCHAIN=$kc KORE_SIGN_NAME=$name scripts/local-sign.sh)
check "  a second run finds it, makes no other" '[[ $again == $name ]] && (( $(count) == 1 ))'
# The test (not install.sh) lets codesign use the key without a dialog: it knows this password.
security set-key-partition-list -S apple-tool:,apple: -s -k "$pw" "$kc" >/dev/null 2>&1

app() { # a tiny app whose binary differs per build
    local dir=$tmp/$1/T.app
    mkdir -p $dir/Contents/MacOS
    print -r -- "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>dev.kore.Kore</string><key>CFBundleExecutable</key><string>T</string></dict></plist>" > $dir/Contents/Info.plist
    print -r -- "int main(void){return $2;}" | clang -x c - -o $dir/Contents/MacOS/T 2>/dev/null
    print -r -- $dir
}
dr() { codesign -d -r- "$1" 2>&1 | sed -n 's/^\(# \)\{0,1\}designated => //p' }
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p' }
one=$(app one 1); two=$(app two 2)
codesign --force --options runtime --keychain "$kc" --sign "$name" "$one" 2>/dev/null
codesign --force --options runtime --keychain "$kc" --sign "$name" "$two" 2>/dev/null
check "two builds signed with it differ (cdhash)" '[[ -n $(cdhash $one) && $(cdhash $one) != $(cdhash $two) ]]'
check "  and keep one designated requirement" '[[ -n $(dr $one) && $(dr $one) == $(dr $two) ]]'
check "  the certificate's: identifier dev.kore.Kore and certificate leaf" '[[ $(dr $one) == *"identifier \"dev.kore.Kore\""*"certificate leaf = H\""* ]]'
adhoc1=$(app a1 1); adhoc2=$(app a2 2)
codesign --force --sign - "$adhoc1" 2>/dev/null; codesign --force --sign - "$adhoc2" 2>/dev/null
check "ad-hoc builds each get their own (why it asks again)" '[[ $(dr $adhoc1) == *cdhash* && $(dr $adhoc1) != $(dr $adhoc2) ]]'

none=$(KORE_SIGN_KEYCHAIN=$tmp/missing.keychain-db KORE_SIGN_NAME=$name scripts/local-sign.sh); code=$?
check "no keychain: prints nothing, exits 0 (the build stays ad-hoc)" '(( code == 0 )) && [[ -z $none ]]'
grep -q 'signed() {' scripts/build-app.sh && grep -q 'signed -$' scripts/build-app.sh
check "build-app.sh falls back to ad-hoc when the identity can't sign" '(( $? == 0 ))'
grep -q 'scripts/local-sign.sh' install.sh
check "install.sh hands the identity to build-app.sh" '(( $? == 0 ))'

(( fails == 0 )) && print "\nall passed" || { print "\n$fails failed"; exit 1; }
