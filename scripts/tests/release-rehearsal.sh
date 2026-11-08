#!/bin/zsh
# A release end to end without GitHub. release.sh --dry-run builds every file into a scratch
# folder and signs SHA256SUMS with a throwaway key; the folder is served on 127.0.0.1 as GitHub
# lays it out, and each update path is pointed at it with the key swapped in (a sed'd copy of the
# scripts, a debug kore-host's KORE_TEST_* overrides, a JVM test's env):
#   Mac     install.sh v<version> (stops before building), and Updater's version order;
#           KORE_REHEARSE_APP=1 also builds Kore.app from the release source into the scratch folder
#   box     kore-host.sh, `kore-host verify`, `update --check`, `update`
#   phone   the app's update check, download and signer check (:link UpdateRehearsalTest)
# Each must take the release and refuse a changed file, an edited SHA256SUMS and a downgrade.
# Nothing is published and nothing outside the scratch folder changes. With the keystore's
# password in the Keychain, kore.apk is the real release-signed one. KORE_HOST_ARCHS="x86_64"
# builds one box binary to save room.
#
#   scripts/tests/release-rehearsal.sh [<scratch folder>]
set -u
cd "${0:A:h:h:h}" || exit 2
repo=$PWD
s=${1:-$(mktemp -d -t kore-rehearsal)}
mkdir -p $s
fails=0
check() { # name, condition
    if eval "$2"; then print -r -- "✔ $1"; else print -r -- "✘ $1"; print -r -- "${out:-}" | sed 's/^/    /'; fails=$((fails+1)); fi
}
sha() { shasum -a 256 "$1" | cut -d' ' -f1 }
V=$(<VERSION)
OLD=0.2.3

# The release.
rel=$s/release
mkdir -p $rel
if [[ ! -f $rel/kore.apk ]] && security find-generic-password -s kore-android-keystore >/dev/null 2>&1; then
    android/scripts/sign-release.sh $rel || print "note: kore.apk didn't build: the phone is rehearsed without it"
fi
out=$(KORE_RELEASE_DIR=$rel scripts/release.sh --dry-run 2>&1); code=$?
print -r -- "$out" > $s/release.log
key=${${out##*throwaway key }%%;*}
check "release.sh --dry-run builds and signs v$V" '(( code == 0 )) && [[ $key =~ "^[A-Za-z0-9+/]{43}=$" ]]'
(( code == 0 )) || { print "see $s/release.log"; exit 1 }
print -r -- "$out" | sed -n '/would publish/,/^$/p'

# Served as GitHub lays a release out, plus two bad copies: a changed file, an edited SHA256SUMS.
srv=$s/srv
rm -rf $srv; mkdir -p $srv/good/download $srv/good/latest
ln -s $rel $srv/good/download/v$V
ln -s ../download/v$V $srv/good/latest/download
for bad in changed edited; do
    mkdir -p $srv/$bad/download/v$V $srv/$bad/latest
    cp $rel/* $srv/$bad/download/v$V/
    ln -s ../download/v$V $srv/$bad/latest/download
done
for f in kore-src.tar.gz kore-host-linux-x86_64.xz kore.apk; do
    [[ -f $srv/changed/download/v$V/$f ]] && print -n x >> $srv/changed/download/v$V/$f
done
sed -i '' 's/^# kore [0-9.]* /# kore 99.0.0 /' $srv/edited/download/v$V/SHA256SUMS
port=$(( 20000 + RANDOM % 20000 ))
python3 -I -m http.server --bind 127.0.0.1 --directory $srv $port >$s/http.log 2>&1 &
server=$!
trap 'kill $server 2>/dev/null' EXIT
url=http://127.0.0.1:$port
curl -fsS --retry 20 --retry-connrefused --retry-max-time 10 -o /dev/null $url/good/latest/download/SHA256SUMS
check "served on $url" '(( $? == 0 ))'

# Mac: install.sh, pinned to the tag as Kore's update runs it.
sed "s|^KORE_RELEASE_KEY=.*|KORE_RELEASE_KEY=\"$key\"|" install.sh > $s/install.sh
mkdir -p $s/mac/Kore.app/Contents
plist() { print "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleShortVersionString</key><string>$1</string></dict></plist>" > $s/mac/Kore.app/Contents/Info.plist }
mac() { # tree, then install.sh v<version>
    rm -rf $s/mac/Kore
    env KORE_RELEASES=$url/$1 KORE_DIR=$s/mac/Kore KORE_APP=$s/mac/Kore.app KORE_NO_BUILD=1 KORE_REPO=$s/no-repo bash $s/install.sh v$V 2>&1
}
plist $OLD
out=$(mac good); code=$?
check "Mac: install.sh takes v$V's signed source" '(( code == 0 )) && [[ $(<$s/mac/Kore/VERSION) == $V && $out == *"Checking Kore $V"* ]]'
out=$(mac changed); code=$?
check "  refuses a changed kore-src.tar.gz" '(( code != 0 )) && [[ ! -e $s/mac/Kore && $out == *"doesn'"'"'t match"* ]]'
out=$(mac edited); code=$?
check "  refuses an edited SHA256SUMS" '(( code != 0 )) && [[ ! -e $s/mac/Kore && $out == *"isn'"'"'t signed"* ]]'
plist 99.0.0
out=$(mac good); code=$?
check "  refuses a downgrade" '(( code != 0 )) && [[ $out == *"newer than $V"* ]]'
# Updater: GitHub's tag against this Mac's version, with ReleaseManifest's order (Updater.newer).
mkdir -p $s/order-src
cat > $s/order-src/main.swift <<'SWIFT'
import Foundation
let a = CommandLine.arguments
let sums = try ReleaseManifest.verified(sums: Data(contentsOf: URL(fileURLWithPath: a[1])), signature: Data(contentsOf: URL(fileURLWithPath: a[2])), key: a[3])
print(a[4...].map { ReleaseManifest.newer(sums.version, than: $0) ? "offer" : "none" }.joined(separator: " "))
SWIFT
curl -fsS -o $s/SHA256SUMS $url/good/latest/download/SHA256SUMS && curl -fsS -o $s/SHA256SUMS.sig $url/good/latest/download/SHA256SUMS.sig
xcrun swiftc -O -package-name kore -o $s/order Sources/KoreCore/ReleaseKey.swift $s/order-src/main.swift 2>$s/order.log
out=$($s/order $s/SHA256SUMS $s/SHA256SUMS.sig $key $OLD $V 99.0.0 2>&1)
check "  Updater offers v$V to $OLD only, not to $V or 99.0.0" '[[ $out == "offer none none" ]]'
# KORE_REHEARSE_APP=1: the curl install's build too, from the release's own source, signed as an
# install signs (this Mac's identity, scripts/local-sign.sh), into the scratch folder only. It
# never runs build-app.sh --install: that would quit Kore and replace /Applications/Kore.app.
if [[ -n ${KORE_REHEARSE_APP:-} ]]; then
    plist $OLD; out=$(mac good)
    ident=$(scripts/local-sign.sh)
    (cd $s/mac/Kore && KORE_SIGN_IDENTITY="$ident" KORE_RELEASES=$url/good KORE_RELEASE_TAG=v$V scripts/build-app.sh > $s/app-build.log 2>&1)
    code=$?; app=$s/mac/Kore/build/Kore.app
    check "Mac: the release source builds Kore.app (${ident:-ad-hoc})" '(( code == 0 )) && [[ -x $app/Contents/MacOS/Kore ]]'
    check "  its version is v$V" '[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $app/Contents/Info.plist) == $V ]]'
    check "  the signature verifies" 'codesign --verify --deep --strict $app 2>/dev/null'
    req=$(codesign -d -r- $app 2>&1 | sed -n 's/^\(# \)\{0,1\}designated => //p')
    if [[ -n $ident ]]; then
        check "  signed by this Mac's identity: same app to macOS across updates" '[[ $req == *"identifier \"dev.kore.Kore\""*"certificate leaf = H\""* ]]'
    fi
fi

# Box: kore-host.sh on a "Linux" x86_64 (a fake uname). The real binary can't run on this Mac, so
# a good release gets as far as running it, after the signature and hash checked out.
mkdir -p $s/linux
print -r -- $'#!/bin/sh\ncase "$1" in -m) echo x86_64;; *) echo Linux;; esac' > $s/linux/uname
chmod +x $s/linux/uname
sed "s|^KORE_RELEASE_KEY=.*|KORE_RELEASE_KEY=\"$key\"|" scripts/kore-host.sh > $s/kore-host.sh
box() { # tree
    rm -rf $s/box; mkdir -p $s/box
    env -i HOME=$s/box PATH="$s/linux:/opt/homebrew/bin:/usr/bin:/bin" KORE_RELEASE_URL=$url/$1/latest/download dash $s/kore-host.sh 2>&1
}
out=$(box good); code=$?
check "box: kore-host.sh checks the signature and hash, then runs the binary" '[[ $out != *"isn'"'"'t signed"* && $out != *"match"* && $out == *"doesn'"'"'t run here"* && ! -e $s/box/.local/bin/kore-host ]]'
out=$(box changed); code=$?
check "  refuses a changed kore-host-linux-x86_64.xz" '(( code != 0 )) && [[ $out == *"doesn'"'"'t match SHA256SUMS"* ]]'
out=$(box edited); code=$?
check "  refuses an edited SHA256SUMS" '(( code != 0 )) && [[ $out == *"isn'"'"'t signed"* ]]'

# Box: kore-host itself, a debug build (KORE_TEST_*), in a scratch home.
swift build --product kore-host >$s/kore-host-build.log 2>&1
check "kore-host builds (debug)" '(( $? == 0 ))'
mkdir -p $s/kh/bin
cp "$(swift build --show-bin-path)/kore-host" $s/kh/bin/kore-host
kh() { # tree, version, then arguments
    local tree=$1 version=$2; shift 2
    env HOME=$s/kh XDG_STATE_HOME=$s/kh/state XDG_RUNTIME_DIR=$s/kh/run XDG_CONFIG_HOME=$s/kh/config \
        KORE_RELEASE_URL=$url/$tree/latest/download KORE_TEST_RELEASE_KEY=$key KORE_TEST_VERSION=$version KORE_TEST_PLATFORM=linux-x86_64 \
        $s/kh/bin/kore-host "$@" 2>&1
}
mkdir -p $s/dl
for f in $(awk 'NR > 1 { print $2 } END { print "SHA256SUMS"; print "SHA256SUMS.sig" }' $rel/SHA256SUMS); do curl -fsS -o $s/dl/$f $url/good/latest/download/$f; done
out=$(kh good $OLD verify $s/dl/SHA256SUMS); code=$?
check "  verify: every file of the release checks out" '(( code == 0 )) && (( $(grep -c "^ok " <<<$out) == $(( $(wc -l < $rel/SHA256SUMS) - 1 )) ))'
out=$(kh good $OLD update --check); code=$?
# Piped, so key: value lines (a terminal's words are HostUpdateFlowTests').
check "  update --check: one line, no binary" '(( code == 0 )) && [[ $out == "update: $V available (have $OLD)" ]]'
out=$(kh good $V update --check)
check "  … and on $V it's the latest" '[[ $out == "update: latest ($V)" ]]'
out=$(kh good 99.0.0 update); code=$?
check "  update refuses a downgrade" '(( code != 0 )) && [[ $out == "error: $V is older than 99.0.0" ]]'
out=$(kh good $OLD update); code=$?
check "  update downloads, checks, then won't swap in a binary that can't run here" '(( code != 0 )) && [[ $out == *"signature: ok"* && $out == *"doesn'"'"'t run here"* ]] && cmp -s $s/kh/bin/kore-host "$(swift build --show-bin-path)/kore-host"'
out=$(kh changed $OLD update); code=$?
check "  update refuses a changed binary" '(( code != 0 )) && [[ $out == *"doesn'"'"'t match its signed hash"* ]]'
out=$(kh edited $OLD update); code=$?
check "  update refuses an edited SHA256SUMS" '(( code != 0 )) && [[ $out == *"isn'"'"'t signed by Kore'"'"'s release key"* ]]'
out=$(kh good $OLD status); code=$?
check "  status shows what the last check found, offline" '[[ $out == *"update   latest, checked "* ]]'

# Phone: the app's own check against the served release (a JVM test), with kore.apk's signer.
if [[ -f $rel/kore.apk ]]; then
    export KORE_ANDROID=$repo/android
    source android/scripts/env.sh
    KORE_STORE_PASS=$(security find-generic-password -s kore-android-keystore -w 2>/dev/null) \
        keytool -exportcert -alias kore -keystore $ANDROID_ROOT/keys/kore-release.jks -storepass:env KORE_STORE_PASS -file $s/cert.der >/dev/null 2>&1
    out=$(KORE_REHEARSAL=$url/good/latest/download KORE_REHEARSAL_KEY=$key KORE_REHEARSAL_CERT=$s/cert.der \
        kore_gradle --offline --no-daemon --quiet :link:test --tests dev.kore.link.UpdateRehearsalTest 2>&1); code=$?
    check "phone: offered to an older app, downloaded, hash and signer checked; refuses changed, edited, downgrade" '(( code == 0 ))'
    printed=$("$ANDROID_HOME"/build-tools/36.0.0/apksigner verify --print-certs $rel/kore.apk | sed -n 's/.*SHA-256 digest: //p' | head -1)
    check "  kore.apk's signer is the pinned release certificate" '[[ ${(U)printed} == ${$(sed -n "s/.*RELEASE_SIGNER = \"\(.*\)\"$/\1/p" android/link/src/main/kotlin/dev/kore/link/update/Release.kt)//:/} ]]'
else
    print "– phone: no kore.apk (keystore password not in the Keychain)"
fi

print ""
print "scratch: $s"
(( fails == 0 )) && print "all passed" || print "$fails failed"
exit $(( fails > 0 ))
