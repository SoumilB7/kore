#!/bin/zsh
# Checks a built Kore.app's `kore`, reached the way an install reaches it: ~/.local/bin/kore,
# a link to Contents/Resources/kore, itself a link to the signed helper. Opening and setup must
# still go through the script beside it and name this app; the signature must hold, also on a
# copy made the way installs and the dmg copy it. No app opens and no real installer runs.
#
#   scripts/tests/kore-app-link.sh [path/to/Kore.app]
set -u
source_app="${1:-${0:A:h:h:h}/build/Kore.app}"
tmp=$(mktemp -d -t kore-app-link)
trap 'rm -rf "$tmp"' EXIT
fails=0
check() { # name, condition
    if eval "$2"; then print -r -- "✔ $1"; else print -r -- "✘ $1"; print -r -- "${out:-}" | sed 's/^/    /'; fails=$((fails+1)); fi
}

# What installs do: ditto, then a link at ~/.local/bin/kore.
app="$tmp/Applications/Kore.app"
mkdir -p "$tmp/Applications" "$tmp/home/.local/bin" "$tmp/bin" "$tmp/work/setup"
ditto "$source_app" "$app"
ln -sf "$app/Contents/Resources/kore" "$tmp/home/.local/bin/kore"

check "Resources/kore is a link to the helper" '[[ -L $app/Contents/Resources/kore && $(readlink $app/Contents/Resources/kore) == ../Helpers/kore ]]'
check "the helper is executable" '[[ -x $app/Contents/Helpers/kore ]]'
out=$(codesign --verify --deep --strict --verbose=2 "$source_app" 2>&1); code=$?
check "built app: codesign --verify --deep --strict" '(( code == 0 ))'
out=$(codesign --verify --deep --strict --verbose=2 "$app" 2>&1); code=$?
check "ditto copy: codesign --verify --deep --strict" '(( code == 0 ))'
out=$(codesign --verify --strict --verbose=2 "$app/Contents/Helpers/kore" 2>&1); code=$?
check "the helper's own signature" '(( code == 0 ))'
out=$(codesign --display --verbose=2 "$app/Contents/Helpers/kore" 2>&1)
check "the helper has the hardened runtime" '[[ $out == *runtime* ]]'

print -r -- '#!/bin/sh
printf "%s\n" "$@" > "$KORE_TEST_OPENED"' > "$tmp/bin/open-stub"
print -r -- '#!/bin/sh
echo "curl stub: real installer reached" >&2; exit 99' > "$tmp/bin/curl"
chmod +x "$tmp/bin/open-stub" "$tmp/bin/curl"
install_codex='mkdir -p $HOME/.local/bin && printf "#!/bin/sh\n" > $HOME/.local/bin/codex && chmod +x $HOME/.local/bin/codex'

run() {
    rm -f "$tmp/opened"
    out=$(cd "$tmp/work" && env -u KORE_SCRIPT HOME="$tmp/home" PATH="$tmp/home/.local/bin:$tmp/bin:/usr/bin:/bin" \
        KORE_SETUP_PATH="$tmp/home/.local/bin" KORE_OPEN="$tmp/bin/open-stub" KORE_TEST_OPENED="$tmp/opened" \
        KORE_SETUP_INSTALL_CODEX="$install_codex" KORE_AGENT_SOCKET="$tmp/no-kore.sock" KORE_AGENT_PASS= \
        kore "$@" 2>&1)
    code=$?
}
opened() { [[ -f "$tmp/opened" ]] && sed -n "$1p" "$tmp/opened" }

run
check "kore opens this app" '(( code == 0 )) && [[ $(opened 1) == -a && $(opened 2) == ${app:A} && -z $(opened 3) ]]'
run .
check "kore . opens this folder in it" '(( code == 0 )) && [[ $(opened 2) == ${app:A} && $(opened 3) == ${tmp:A}/work ]]'
run ./setup
check "kore ./setup opens the folder" '(( code == 0 )) && [[ $(opened 3) == ${tmp:A}/work/setup ]]'
run nope
check "kore <missing> says so" '(( code == 1 )) && [[ $out == *"not a folder: nope"* && ! -f $tmp/opened ]]'
run setup codex
check "kore setup codex runs the script's setup" '(( code == 0 )) && [[ $out == *"✓ Codex installed"* && -x $tmp/home/.local/bin/codex && ! -f $tmp/opened ]]'
run help
check "kore help" '(( code == 0 )) && [[ $out == usage:* && $out == *"kore setup"* && $out == *"kore ls"* ]]'
run ls
check "kore ls with no Kore: exit 5" '(( code == 5 ))'

helper=$(stat -f %z "$app/Contents/Helpers/kore")
script=$(stat -f %z "$app/Contents/Resources/kore.zsh")
total=$(du -sk "$app" | cut -f1)
print "helper $helper bytes, script $script bytes, app ${total} KB; the helper is what this adds"

(( fails == 0 )) && print "all passed" || { print "$fails failed"; exit 1 }
