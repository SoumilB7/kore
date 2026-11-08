#!/bin/zsh
# scripts/tailnet-helper.sh (build-app.sh's kore-tailnet) against a release folder made here and
# read over file://, signed with a throwaway key: no network, no Keychain, no real Go, nothing
# published. It runs from a scratch copy of the repo whose ReleaseKey.swift holds that key; a fake
# `go` stands in for the source build and a `curl` wrapper notes every URL asked for.
#
#   scripts/tests/tailnet-helper.sh
set -u
cd "${0:A:h:h:h}" || exit 2
tmp=$(mktemp -d -t kore-tailnet-helper)
trap 'rm -rf "$tmp"' EXIT
fails=0
check() { # name, condition
    if eval "$2"; then print -r -- "✔ $1"; else print -r -- "✘ $1"; print -r -- "${out:-}" | sed 's/^/    /'; fails=$((fails+1)); fi
}
sha() { shasum -a 256 "$1" | cut -d' ' -f1 }
commit=$(git rev-parse HEAD)
NAME=kore-tailnet-macos-arm64

out=$(zsh -n scripts/tailnet-helper.sh scripts/build-tailnet.sh scripts/build-app.sh 2>&1)
check "tailnet-helper.sh, build-tailnet.sh and build-app.sh parse (zsh -n)" '(( $? == 0 ))'
check "build-app.sh puts kore-tailnet in Helpers through tailnet-helper.sh" \
    'grep -qF '"'"'scripts/tailnet-helper.sh "$APP/Contents/Helpers/kore-tailnet"'"'"' scripts/build-app.sh'

# The scratch repo: the scripts it runs, the key file it reads.
root=$tmp/repo
mkdir -p $root/scripts/sign $root/Sources/KoreCore $root/tools/kore-tailnet $tmp/bin $tmp/home
cp scripts/tailnet-helper.sh scripts/build-tailnet.sh $root/scripts/
cp scripts/sign/sign.swift $root/scripts/sign/
cp tools/kore-tailnet/build-tags $root/tools/kore-tailnet/
cp Sources/KoreCore/ReleaseKey.swift $root/Sources/KoreCore/
setkey() { sed -i '' "s|static let base64 = \".*\"\$|static let base64 = \"$1\"|" $root/Sources/KoreCore/ReleaseKey.swift }

# Fakes: curl noting its URLs, then the real one; go "building" a script that says "built".
print -r -- "#!/bin/sh
for a; do case \$a in *://*) echo \"\$a\" >> $tmp/curl.log ;; esac; done
exec /usr/bin/curl \"\$@\"" > $tmp/bin/curl
print -r -- '#!/bin/sh
[ -z "$FAKE_GO_FAIL" ] || { echo "go: build failed" >&2; exit 1; }
while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
printf "#!/bin/sh\necho built\n" > "$out"; chmod +x "$out"' > $tmp/bin/fakego
chmod +x $tmp/bin/curl $tmp/bin/fakego

# The release, v9.9.9, at download/v9.9.9 and latest/download.
rel=$tmp/gh/download/v9.9.9
mkdir -p $rel $tmp/gh/latest
ln -s ../download/v9.9.9 $tmp/gh/latest/download
print -r -- $'#!/bin/sh\necho release' > $rel/$NAME
print -r -- 'kore-host.sh' > $rel/kore-host.sh
release() { # files listed in SHA256SUMS; signs it, the scratch repo takes the key
    { print "# kore 9.9.9 $commit"; for f in "$@"; do print "$(sha $rel/$f)  $f"; done } > $rel/SHA256SUMS
    setkey "$(swift scripts/sign/sign.swift sign --ephemeral $rel/SHA256SUMS)"
}

dest=$tmp/Kore.app/Contents/Helpers/kore-tailnet
helper() { # [env…]: no Go unless given; prints its output, returns its status
    rm -f $tmp/curl.log; touch $tmp/curl.log
    env -i HOME=$tmp/home PATH="$tmp/bin:/usr/bin:/bin" KORE_RELEASES=file://$tmp/gh KORE_GO=/var/empty/no-go "$@" \
        zsh $root/scripts/tailnet-helper.sh $dest 2>&1
}
says() { [[ -x $dest && $($dest) == $1 ]] }
signed() { codesign -v $dest 2>/dev/null && codesign -dv $dest 2>&1 | grep -q '^Signature=adhoc' }
asked() { [[ -s $tmp/curl.log ]] }
offline() { ! grep -qv '^file://' $tmp/curl.log }

# Placeholder key: nothing downloaded, one note.
out=$(helper); code=$?
check "placeholder key: one note, no helper, the build goes on" '(( code == 0 )) && [[ ! -e $dest && $out == *"note: Kore.app ships without kore-tailnet (no Go, and no release key"* ]]'
check "  and nothing is downloaded" '! asked'

# A good release: verified, installed, executable, ad-hoc signed, no quarantine.
release kore-host.sh $NAME
mkdir -p $root/build/release; print -r -- $'#!/bin/sh\necho stale' > $root/build/release/$NAME; chmod +x $root/build/release/$NAME
out=$(helper); code=$?
check "no Go: the latest release's kore-tailnet installs" '(( code == 0 )) && says release && [[ $out == *"release 9.9.9'"'"'s, checked against its signed SHA256SUMS"* ]]'
check "  executable and ad-hoc signed like the app" 'signed'
check "  without quarantine" '! xattr -p com.apple.quarantine $dest 2>/dev/null'
check "  never an older build left in build/release" '[[ ! -e $root/build/release/$NAME ]]'
check "  from latest/download, over file:// only" 'grep -q "/latest/download/$NAME\$" $tmp/curl.log && offline'
out=$(helper KORE_RELEASE_TAG=v9.9.9); code=$?
check "KORE_RELEASE_TAG takes it from that release" '(( code == 0 )) && says release && grep -q "/download/v9.9.9/$NAME\$" $tmp/curl.log && ! grep -q latest $tmp/curl.log'

# Tampered: the asset, then the signature. A helper there before is gone either way.
cp $rel/$NAME $tmp/asset.good
print -r -- $'#!/bin/sh\necho evil' > $rel/$NAME
out=$(helper); code=$?
check "an asset that doesn't match its signed SHA-256 is refused, the build goes on" '(( code == 0 )) && [[ ! -e $dest && $out == *"doesn'"'"'t match its signed SHA-256"* ]]'
cp $tmp/asset.good $rel/$NAME
helper >/dev/null
cp $rel/SHA256SUMS.sig $tmp/sig.good
swift scripts/sign/sign.swift sign --ephemeral $rel/SHA256SUMS >/dev/null
out=$(helper); code=$?
check "a signature by another key is refused, the build goes on" '(( code == 0 )) && [[ ! -e $dest && $out == *"isn'"'"'t signed by Kore'"'"'s release key"* ]]'
check "  before the asset is downloaded" '! grep -q "$NAME\$" $tmp/curl.log'
cp $tmp/sig.good $rel/SHA256SUMS.sig
print x >> $rel/SHA256SUMS
out=$(helper); code=$?
check "an edited SHA256SUMS is refused" '(( code == 0 )) && [[ ! -e $dest && $out == *"isn'"'"'t signed"* ]]'

# Missing: a release without the asset, then no release at all.
release kore-host.sh
out=$(helper); code=$?
check "a release without kore-tailnet: one note, the build goes on" '(( code == 0 )) && [[ ! -e $dest && $out == *"release 9.9.9 has no $NAME yet"* ]] && (( $(grep -c "^note:" <<<$out) == 1 ))'
out=$(helper KORE_RELEASES=file://$tmp/nowhere); code=$?
check "no release at all: one note, the build goes on" '(( code == 0 )) && [[ ! -e $dest && $out == *"no signed release to download it from"* ]]'

# Go: built from source, nothing downloaded; a failed build falls back to the release.
release kore-host.sh $NAME
out=$(helper KORE_GO=$tmp/bin/fakego); code=$?
check "with Go it's built from source" '(( code == 0 )) && says built && signed && [[ $out == *"built from source"* ]]'
check "  and nothing is downloaded" '! asked'
out=$(helper KORE_GO=$tmp/bin/fakego FAKE_GO_FAIL=1); code=$?
check "a failed Go build falls back to the signed release" '(( code == 0 )) && says release && [[ $out == *"didn'"'"'t build from source"* ]]'

print ""
(( fails == 0 )) && print "all passed" || print "$fails failed"
exit $(( fails > 0 ))
