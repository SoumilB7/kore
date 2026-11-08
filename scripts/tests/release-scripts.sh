#!/bin/zsh
# The release scripts against a release folder made here, signed with a throwaway key: no
# network, no Keychain, nothing published, nothing built. kore-host.sh runs under dash with a fake
# `uname` (Linux) and a fake kore-host; install.sh stops before building (KORE_NO_BUILD).
#
#   scripts/tests/release-scripts.sh
set -u
cd "${0:A:h:h:h}" || exit 2
repo=$PWD
tmp=$(mktemp -d -t kore-release-scripts)
trap 'rm -rf "$tmp"' EXIT
fails=0
check() { # name, condition
    if eval "$2"; then print -r -- "✔ $1"; else print -r -- "✘ $1"; print -r -- "${out:-}" | sed 's/^/    /'; fails=$((fails+1)); fi
}
sign() { swift scripts/sign/sign.swift "$@" }
sha() { shasum -a 256 "$1" | cut -d' ' -f1 }
commit=$(git rev-parse HEAD)

# Syntax: POSIX sh for the box installer, bash and zsh for the rest.
out=$(dash -n scripts/kore-host.sh 2>&1); check "kore-host.sh is POSIX sh (dash -n)" '(( $? == 0 ))'
out=$(bash -n install.sh 2>&1); check "install.sh parses (bash -n)" '(( $? == 0 ))'
out=$(zsh -n scripts/release.sh scripts/build-host.sh 2>&1); check "release.sh and build-host.sh parse (zsh -n)" '(( $? == 0 ))'

# Fakes: Linux on x86_64, and an openssl without Ed25519.
mkdir -p $tmp/linux $tmp/oldssl
print -r -- $'#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo x86_64;; *) echo Linux;; esac' > $tmp/linux/uname
print -r -- $'#!/bin/sh\necho "usage: pkeyutl [-in file] [-sigfile file]"' > $tmp/oldssl/openssl
chmod +x $tmp/linux/uname $tmp/oldssl/openssl
# A kore-host that says 9.9.9, answers `verify` with $FAKE_VERIFY (0 by default) and notes install-service.
fake_host() { # version
    print -r -- "#!/bin/sh
case \"\$1\" in
  --version) echo 'kore-host $1 (link 1.12)' ;;
  verify) exit \${FAKE_VERIFY:-0} ;;
  install-service) touch \"\$HOME/service-installed\"; echo 'kore-host is running' ;;
esac"
}

# A release: SHA256SUMS over kore-host-linux-x86_64.xz and kore-host.sh, signed.
rel=$tmp/rel
mkdir -p $rel
fake_host 9.9.9 | xz -c > $rel/kore-host-linux-x86_64.xz
cp scripts/kore-host.sh $rel/kore-host.sh
{ print "# kore 9.9.9 $commit"; for f in kore-host-linux-x86_64.xz kore-host.sh; do print "$(sha $rel/$f)  $f"; done } > $rel/SHA256SUMS
key=$(sign sign --ephemeral $rel/SHA256SUMS)
check "sign --ephemeral writes a 64-byte signature" '[[ $(stat -f %z $rel/SHA256SUMS.sig) == 64 ]]'
out=$(sign verify $rel/SHA256SUMS $rel/SHA256SUMS.sig $key 2>&1); check "sign verify accepts it" '(( $? == 0 ))'
if [[ -x /opt/homebrew/bin/openssl ]]; then
    print -- "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEA$key\n-----END PUBLIC KEY-----" > $tmp/key.pem
    out=$(/opt/homebrew/bin/openssl pkeyutl -verify -pubin -inkey $tmp/key.pem -rawin -in $rel/SHA256SUMS -sigfile $rel/SHA256SUMS.sig 2>&1)
    check "openssl pkeyutl -rawin accepts it, as kore-host.sh checks it" '(( $? == 0 ))'
fi
sed "s|^KORE_RELEASE_KEY=.*|KORE_RELEASE_KEY=\"$key\"|" scripts/kore-host.sh > $tmp/kore-host.sh

# kore-host.sh into a fresh home, with this PATH first; prints its output, returns its status.
box() { # path-first, [env…]
    local first=$1; shift
    rm -rf $tmp/home; mkdir -p $tmp/home
    env -i HOME=$tmp/home PATH="$first:$tmp/linux:/opt/homebrew/bin:/usr/bin:/bin" KORE_RELEASE_URL=file://$rel "$@" dash $tmp/kore-host.sh 2>&1
}
installed() { [[ -x $tmp/home/.local/bin/kore-host && -f $tmp/home/service-installed ]] }

out=$(box $tmp/linux); code=$?
check "kore-host.sh installs a signed release and its service" '(( code == 0 )) && installed'
check "  and prints the next step" '[[ $out == *"Next: kore-host join"* ]]'
check "  leaving nothing staged" '[[ $(ls -A $tmp/home/.local/bin) == kore-host ]]'
out=$(box $tmp/oldssl); code=$?
check "without Ed25519 openssl it says so and the new kore-host verifies" '(( code == 0 )) && installed && [[ $out == *"openssl can'"'"'t check Ed25519"* ]]'
out=$(box $tmp/oldssl FAKE_VERIFY=1); code=$?
check "  a signature that kore-host refuses installs nothing" '(( code != 0 )) && ! installed'

cp $rel/SHA256SUMS $tmp/sums.good
sed -i '' '1s/9.9.9/9.9.8/' $rel/SHA256SUMS
out=$(box $tmp/linux); code=$?
check "a version edited after signing installs nothing" '(( code != 0 )) && ! installed && [[ $out == *"isn'"'"'t signed"* ]]'
cp $tmp/sums.good $rel/SHA256SUMS
cp $rel/kore-host-linux-x86_64.xz $tmp/xz.good
fake_host 9.9.9 | sed 's/link/evil/' | xz -c > $rel/kore-host-linux-x86_64.xz
out=$(box $tmp/linux); code=$?
check "a binary that doesn't match SHA256SUMS installs nothing" '(( code != 0 )) && ! installed && [[ $out == *"doesn'"'"'t match"* ]]'
cp $tmp/xz.good $rel/kore-host-linux-x86_64.xz
rm -rf $tmp/home; mkdir -p $tmp/home
out=$(env -i HOME=$tmp/home PATH="$tmp/linux:/opt/homebrew/bin:/usr/bin:/bin" KORE_RELEASE_URL=file://$rel dash scripts/kore-host.sh 2>&1); code=$?
check "the real kore-host.sh refuses a release another key signed" '(( code != 0 )) && ! installed && [[ $out == *"isn'"'"'t signed"* ]]'

# release.sh --dry-run over a folder with fake kore-host builds.
dry=$tmp/dry
mkdir -p $dry
for a in x86_64 aarch64; do print "fake $a" | xz -c > $dry/kore-host-linux-$a.xz; done
# No Go (nothing built); kore-tailnet builds left in build/release are taken, as release.sh would.
out=$(KORE_RELEASE_DIR=$dry KORE_GO=/var/empty/no-go scripts/release.sh --dry-run 2>&1); code=$?
tailnets=$(ls $dry | grep -c '^kore-tailnet-')
tailnet_skipped() { [[ -f $dry/kore-tailnet-macos-arm64 || $out == *"skipped kore-tailnet-macos-arm64"* ]] }
check "release.sh --dry-run plans without publishing" '(( code == 0 )) && [[ $out == *"Kore $(<VERSION) ("*"as the latest release"* && $out == *"nothing published"* ]]'
check "  SHA256SUMS: the version line, then every asset" '[[ $(head -1 $dry/SHA256SUMS) == "# kore $(<VERSION) $commit" ]] && (( $(wc -l < $dry/SHA256SUMS) == 5 + tailnets ))'
check "  kore-host.sh is listed with its hash" 'grep -qx "$(sha scripts/kore-host.sh)  kore-host.sh" $dry/SHA256SUMS'
check "  signed (64 bytes)" '[[ $(stat -f %z $dry/SHA256SUMS.sig) == 64 ]]'
check "  absent kore-tailnet and kore.apk are skipped" '[[ $out == *"skipped kore.apk (not built)"* ]] && tailnet_skipped'
check "  says which releases and tags are there already" '[[ $out == *"already there: releases"* ]]'
# Publishing takes only a prepared, signed folder for this commit, and asks on a terminal.
pub=$(KORE_RELEASE_DIR=$tmp/none scripts/release.sh 2>&1 </dev/null); code=$?
check "release.sh with nothing prepared publishes nothing" '(( code != 0 )) && [[ $pub == *"nothing prepared"* ]]'
other=$tmp/other; mkdir -p $other; cp $dry/SHA256SUMS $dry/SHA256SUMS.sig $other/
sed -i '' "1s/.*/# kore $(<VERSION) 0000000000000000000000000000000000000000/" $other/SHA256SUMS
pub=$(KORE_RELEASE_DIR=$other scripts/release.sh 2>&1 </dev/null); code=$?
check "  nor a folder prepared for another commit" '(( code != 0 )) && [[ $pub == *"another commit"* ]]'
grep -q '/dev/tty' scripts/release.sh; check "  and the yes is read from the terminal" '(( $? == 0 ))'
# Boxes' own tailnet: listed when built (Go here, or left in build/release), else said skipped.
box_tailnets() {
    local a
    for a in x86_64 aarch64; do
        if [[ -f $dry/kore-tailnet-linux-$a.xz ]]; then grep -q "  kore-tailnet-linux-$a.xz\$" $dry/SHA256SUMS || return 1
        else [[ $out == *"skipped kore-tailnet-linux-$a.xz (not built)"* ]] || return 1; fi
    done
}
check "  boxes' tailnet: listed when built, else skipped" 'box_tailnets'
notes=$dry/notes.md
drykey=${${out##*throwaway key }%%)*}
check "  notes: the title, three installs, what's new, the signer line" '[[ $(head -1 $notes) == "# Kore $(<VERSION)" ]] && grep -q "install.sh | bash" $notes && grep -q "kore-host.sh | sh" $notes && grep -q "kore.apk](" $notes && grep -q "^### What.s new" $notes && grep -qF "release key \`$drykey\`" $notes'
bullets=$(awk '/^### What/ { on = 1; next } on && /^- / { n++ } on && /^$/ && n { exit } END { print n + 0 }' $notes)
check "  3 to 6 one-line highlights" '(( bullets >= 3 && bullets <= 6 ))'
check "  the source tarball holds this commit" '[[ $(tar -xzOf $dry/kore-src.tar.gz kore/VERSION) == $(<VERSION) ]]'

# install.sh: a signed release v9.9.9 from a file:// "GitHub".
gh=$tmp/gh/download/v9.9.9
mkdir -p $gh $tmp/src/kore/scripts
print 9.9.9 > $tmp/src/kore/VERSION
# A build-app.sh that only says what install.sh handed it.
print -r -- '#!/bin/sh
echo "build-app $1 releases=$KORE_RELEASES tag=$KORE_RELEASE_TAG"' > $tmp/src/kore/scripts/build-app.sh
chmod +x $tmp/src/kore/scripts/build-app.sh
tar -czf $gh/kore-src.tar.gz -C $tmp/src kore
signed_install() { # version in SHA256SUMS
    print "# kore $1 $commit\n$(sha $gh/kore-src.tar.gz)  kore-src.tar.gz" > $gh/SHA256SUMS
    sign sign --ephemeral $gh/SHA256SUMS
}
key=$(signed_install 9.9.9)
sed "s|^KORE_RELEASE_KEY=.*|KORE_RELEASE_KEY=\"$key\"|" install.sh > $tmp/install.sh
mkdir -p $tmp/app/Contents
plist() { print "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleShortVersionString</key><string>$1</string></dict></plist>" > $tmp/app/Contents/Info.plist }
kdir=$tmp/kore
mac() { # [env…] then install.sh v9.9.9
    env KORE_RELEASES=file://$tmp/gh KORE_DIR=$kdir KORE_APP=$tmp/app KORE_NO_BUILD=1 KORE_REPO=$tmp/norepo "$@" bash $tmp/install.sh v9.9.9 2>&1
}
fresh() { rm -rf $kdir; mkdir -p $kdir/.build; print cache > $kdir/.build/kept; print old > $kdir/VERSION }

plist 0.2.3; fresh
out=$(mac); code=$?
check "install.sh builds a signed release from its checked source" '(( code == 0 )) && [[ $(<$kdir/VERSION) == 9.9.9 ]]'
check "  keeping the build cache" '[[ $(<$kdir/.build/kept) == cache ]]'
out=$(mac KORE_NO_BUILD= KORE_NO_OPEN=1); code=$?
check "  build-app.sh gets the release and its tag (kore-tailnet's fallback)" '(( code == 0 )) && [[ $out == *"build-app --install releases=file://$tmp/gh tag=v9.9.9"* ]]'
cp $tmp/src/kore/VERSION $tmp/v.good
print 9.9.9-evil > $tmp/src/kore/VERSION; tar -czf $tmp/evil.tar.gz -C $tmp/src kore; cp $tmp/v.good $tmp/src/kore/VERSION
cp $gh/kore-src.tar.gz $tmp/src.good; cp $tmp/evil.tar.gz $gh/kore-src.tar.gz; fresh
out=$(mac); code=$?
check "a tarball that doesn't match the signed sum changes nothing" '(( code != 0 )) && [[ $(<$kdir/VERSION) == old && $out == *"doesn'"'"'t match"* ]]'
cp $tmp/src.good $gh/kore-src.tar.gz
print x >> $gh/SHA256SUMS; fresh
out=$(mac); code=$?
check "an edited SHA256SUMS changes nothing" '(( code != 0 )) && [[ $(<$kdir/VERSION) == old && $out == *"isn'"'"'t signed"* ]]'
key2=$(signed_install 9.9.8); sed "s|^KORE_RELEASE_KEY=.*|KORE_RELEASE_KEY=\"$key2\"|" install.sh > $tmp/install.sh; fresh
out=$(mac); code=$?
check "a signed manifest for another version than the tag changes nothing" '(( code != 0 )) && [[ $(<$kdir/VERSION) == old && $out == *"another release"* ]]'
key=$(signed_install 9.9.9); sed "s|^KORE_RELEASE_KEY=.*|KORE_RELEASE_KEY=\"$key\"|" install.sh > $tmp/install.sh
plist 10.0.0; fresh
out=$(mac); code=$?
check "an older release than the installed Kore is refused" '(( code != 0 )) && [[ $(<$kdir/VERSION) == old && $out == *"newer than 9.9.9"* ]]'
out=$(mac KORE_FORCE=1); code=$?
check "  and installed with KORE_FORCE=1" '(( code == 0 )) && [[ $(<$kdir/VERSION) == 9.9.9 ]]'
# No signature: today's git flow, with one note.
plist 0.2.3; rm $gh/SHA256SUMS.sig
git init -q $tmp/norepo && print 9.9.9 > $tmp/norepo/VERSION && git -C $tmp/norepo add VERSION \
    && git -C $tmp/norepo -c user.name=t -c user.email=t@t commit -qm v
rm -rf $kdir
out=$(mac); code=$?
check "a release without a signature builds from git, with one note" '(( code == 0 )) && [[ -d $kdir/.git && $out == *"v9.9.9 has no signature"* ]]'

print ""
(( fails == 0 )) && print "all passed" || print "$fails failed"
exit $(( fails > 0 ))
