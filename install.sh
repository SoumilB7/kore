#!/bin/bash
# Install or update Kore:
#   curl -fsSL https://raw.githubusercontent.com/SoumilB7/kore/main/install.sh | bash
# Always the latest version. Run it again to update.
#
# Builds Kore on this Mac, so there's no unsigned download for macOS to block, puts it in
# /Applications and links the `kore` command.
set -euo pipefail

REPO="${KORE_REPO:-https://github.com/SoumilB7/kore.git}"
DIR="${KORE_DIR:-$HOME/.kore/Kore}"

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
