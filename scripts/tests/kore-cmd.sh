#!/bin/zsh
# Tests scripts/kore with fake installers and a stubbed `open` in a temp HOME:
# no app opens and no real installer runs.
set -u
zmodload zsh/datetime

kore="${0:A:h:h}/kore"
tmp=$(mktemp -d -t kore-cmd-test)
trap 'rm -rf "$tmp"' EXIT
fails=0

# Fresh HOME per case; `curl` is shadowed so a missed override can't download anything.
reset() {
    rm -rf "$tmp/home"
    mkdir -p "$tmp/home/.local/bin" "$tmp/bin" "$tmp/work/setup"
    print '#!/bin/sh\necho "curl stub: real installer reached" >&2; exit 99' > "$tmp/bin/curl"
    cat > "$tmp/bin/open-stub" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "$KORE_TEST_OPENED"
STUB
    chmod +x "$tmp/bin/curl" "$tmp/bin/open-stub"
    rm -f "$tmp/opened"
}
# A fake installer that drops an executable `$1` into ~/.local/bin.
fake_install() { print -r -- "echo noise from $1 installer; mkdir -p \$HOME/.local/bin && printf '#!/bin/sh\n' > \$HOME/.local/bin/$1 && chmod +x \$HOME/.local/bin/$1" }

run() {
    out=$(cd "$tmp/work" && HOME="$tmp/home" PATH="$tmp/bin:/usr/bin:/bin" \
        KORE_SETUP_PATH="$tmp/home/.local/bin" KORE_OPEN="$tmp/bin/open-stub" KORE_TEST_OPENED="$tmp/opened" \
        KORE_SETUP_INSTALL_CLAUDE="${INSTALL_CLAUDE:-$(fake_install claude)}" \
        KORE_SETUP_INSTALL_CODEX="${INSTALL_CODEX:-$(fake_install codex)}" \
        zsh "$kore" "$@" 2>&1)
    code=$?
}
check() { # name, condition
    if eval "$2"; then print -r -- "✔ $1"; else print -r -- "✘ $1"; print -r -- "$out" | sed 's/^/    /'; fails=$((fails+1)); fi
}
# What `open` got, one argument per line.
opened_first() { [[ -f "$tmp/opened" ]] && head -n 1 "$tmp/opened" }
opened_last() { [[ -f "$tmp/opened" ]] && tail -n 1 "$tmp/opened" }
opened_n() { [[ -f "$tmp/opened" ]] && wc -l < "$tmp/opened" | tr -d " " }

reset; run setup
check "setup, neither installed" '(( code == 0 )) && [[ $out == *"✓ Claude Code installed"* && $out == *"✓ Codex installed"* && $out != *noise* ]] && [[ -x $tmp/home/.local/bin/claude && -x $tmp/home/.local/bin/codex ]]'

reset; print '#!/bin/sh' > "$tmp/home/.local/bin/claude"; chmod +x "$tmp/home/.local/bin/claude"; run setup
check "setup, claude already installed" '(( code == 0 )) && [[ $out == *"claude: already installed ($tmp/home/.local/bin/claude)"* && $out == *"✓ Codex installed"* && $out != *"Installing Claude"* ]]'

reset; run setup; run setup
check "setup, both installed" '(( code == 0 )) && [[ $out == *"claude: already installed"* && $out == *"codex: already installed"* && $out != *Installing* ]]'

reset; INSTALL_CODEX='echo downloading; echo "error: network unreachable" >&2; exit 3' run setup
check "setup, failing installer" '(( code != 0 )) && [[ $out == *"✓ Claude Code installed"* && $out == *"✗ Codex: error: network unreachable"* && $out != *downloading* ]]'

reset; INSTALL_CLAUDE='true' run setup claude
check "setup, installer succeeds but no binary" '(( code != 0 )) && [[ $out == *"✗ Claude Code: installed, but claude isn'"'"'t on PATH"* ]]'

reset; run setup codex
check "setup codex only" '(( code == 0 )) && [[ $out == *"✓ Codex installed"* && $out != *Claude* && ! -e $tmp/home/.local/bin/claude ]]'

reset; run setup claude --verbose
check "setup --verbose shows installer output" '(( code == 0 )) && [[ $out == *"noise from claude installer"* && $out == *"✓ Claude Code installed"* ]]'

reset; run setup bogus
check "setup, unknown argument" '(( code != 0 )) && [[ $out == *"unknown: bogus"* && ! -e $tmp/home/.local/bin/claude ]]'

reset; run .
check "kore ." '(( code == 0 )) && [[ $(opened_n) == 3 && $(opened_first) == -a && $(opened_last) == "${tmp:A}/work" ]]'

reset; run ./setup
check "kore ./setup opens the folder" '(( code == 0 )) && [[ $(opened_n) == 3 && $(opened_last) == "${tmp:A}/work/setup" ]]'

reset; run "$tmp/work/setup"
check "kore <dir>" '(( code == 0 )) && [[ $(opened_n) == 3 && $(opened_last) == "${tmp:A}/work/setup" ]]'

reset; run nope
check "kore <missing>" '(( code == 1 )) && [[ $out == *"not a folder: nope"* && ! -f $tmp/opened ]]'

reset; run
check "bare kore opens the app only" '(( code == 0 )) && [[ $(opened_n) == 2 && $(opened_first) == -a ]]'

for a in help -h; do
    reset; run $a
    check "kore $a" '(( code == 0 )) && [[ $out == usage:* && $out == *"kore setup"* && ! -f $tmp/opened ]]'
done

# The `kore` binary (KORE_BIN, the built kore-command) hands opening and setup to this script
# as before, and refuses its reads at once while no Kore listens.
if [[ -n ${KORE_BIN:-} ]]; then
    runbin() {
        out=$(cd "$tmp/work" && HOME="$tmp/home" PATH="$tmp/bin:/usr/bin:/bin" KORE_SCRIPT="$kore" \
            KORE_SETUP_PATH="$tmp/home/.local/bin" KORE_OPEN="$tmp/bin/open-stub" KORE_TEST_OPENED="$tmp/opened" \
            KORE_SETUP_INSTALL_CLAUDE="$(fake_install claude)" KORE_SETUP_INSTALL_CODEX="$(fake_install codex)" \
            KORE_AGENT_SOCKET="$tmp/no-kore.sock" KORE_AGENT_PASS= \
            "$KORE_BIN" "$@" 2>&1)
        code=$?
    }
    reset; runbin
    check "binary: bare kore opens the app only" '(( code == 0 )) && [[ $(opened_n) == 2 && $(opened_first) == -a ]]'
    reset; runbin .
    check "binary: kore ." '(( code == 0 )) && [[ $(opened_n) == 3 && $(opened_last) == "${tmp:A}/work" ]]'
    reset; runbin ./setup
    check "binary: kore ./setup opens the folder" '(( code == 0 )) && [[ $(opened_last) == "${tmp:A}/work/setup" ]]'
    reset; mkdir -p "$tmp/work/ls"; runbin ./ls
    check "binary: kore ./ls opens the folder named like a command" '(( code == 0 )) && [[ $(opened_last) == "${tmp:A}/work/ls" ]]'
    reset; runbin nope
    check "binary: kore <missing>" '(( code == 1 )) && [[ $out == *"not a folder: nope"* && ! -f $tmp/opened ]]'
    reset; runbin setup --help
    check "binary: kore setup --help" '(( code == 0 )) && [[ $out == *"kore setup"* && ! -e $tmp/home/.local/bin/claude && ! -f $tmp/opened ]]'
    reset; runbin setup codex
    check "binary: kore setup codex" '(( code == 0 )) && [[ $out == *"✓ Codex installed"* && $out != *Claude* ]]'
    reset; runbin help
    check "binary: kore help" '(( code == 0 )) && [[ $out == usage:* && $out == *"kore setup"* && $out == *"kore ls"* ]]'
    reset; s=$EPOCHREALTIME; runbin ls; ms=$(( (EPOCHREALTIME - s) * 1000 ))
    check "binary: kore ls with no Kore: exit 5 at once ($(printf %.0f $ms) ms)" '(( code == 5 && ms < 500 )) && [[ $out == "kore: Kore isn'"'"'t running, or agent control is off." ]]'
    reset; runbin log
    check "binary: kore log with no chat: usage, exit 2" '(( code == 2 )) && [[ $out == *"kore log <chat>"* ]]'
    reset; runbin ls --bogus
    check "binary: an unknown option: exit 2" '(( code == 2 )) && [[ $out == *"unknown option --bogus"* ]]'
fi

(( fails == 0 )) && print "all passed" || { print "$fails failed"; exit 1 }
