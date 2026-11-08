#!/bin/zsh
# Builds kore-tailnet (tools/kore-tailnet, Go tsnet) into build/release/: kore-tailnet-macos-arm64
# for Kore.app's Helpers, kore-tailnet-linux-{x86_64,aarch64}.xz for boxes without tailscaled.
# Static (no cgo), stripped, with tsnet features Kore doesn't use left out (build-tags). Without
# Go it says so and builds nothing, so build-host.sh and release.sh still run.
#
#   scripts/build-tailnet.sh [macos-arm64] [linux-x86_64] [linux-aarch64]      (all when none)
set -euo pipefail

cd "${0:A:h}/.."
OUT="$PWD/build/release"
targets=("$@")
(( $# )) || targets=(macos-arm64 linux-x86_64 linux-aarch64)

GO="${KORE_GO:-$(command -v go || true)}"
[[ -z $GO && -x /opt/homebrew/bin/go ]] && GO=/opt/homebrew/bin/go
if [[ ! -x $GO ]]; then
    print "skipped kore-tailnet: no Go (brew install go, or KORE_GO=<path>)"
    exit 0
fi
command -v xz >/dev/null || { print -u2 "needs xz (brew install xz)"; exit 1; }
mkdir -p "$OUT"
tags="$(paste -sd, tools/kore-tailnet/build-tags)"

for target in $targets; do
    case $target in
        macos-arm64) os=darwin arch=arm64 ;;
        linux-x86_64) os=linux arch=amd64 ;;
        linux-aarch64) os=linux arch=arm64 ;;
        *) print -u2 "unknown target $target: macos-arm64, linux-x86_64 or linux-aarch64"; exit 1 ;;
    esac
    bin="$OUT/kore-tailnet-$target"
    (cd tools/kore-tailnet && CGO_ENABLED=0 GOOS=$os GOARCH=$arch "$GO" build -trimpath -buildvcs=false \
        -ldflags "-s -w" -tags "$tags" -o "$bin" .)
    if [[ $os == linux ]]; then
        xz -9 -T0 -f "$bin"
        bin="$bin.xz"
    fi
    echo "built ${bin#$PWD/} ($(( $(stat -f %z "$bin") / 1024 )) KB)"
done
