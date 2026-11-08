#!/bin/zsh
# Builds what a release carries for boxes into build/release/: kore-host for Linux, static (musl)
# and stripped, packed with xz. Needs the swift.org toolchain BoxBuild uses, with its Static Linux
# SDK (`swift sdk install …static-linux…`), and xz.
#
#   scripts/build-host.sh [x86_64] [aarch64]      (both when none is named)
set -euo pipefail

cd "${0:A:h}/.."
SWIFT="${KORE_LINUX_SWIFT:-$HOME/Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain/usr/bin/swift}"
OUT=build/release
archs=("$@")
(( $# )) || archs=(x86_64 aarch64)

[[ -x "$SWIFT" ]] || { print -u2 "no $SWIFT: install the swift.org 6.4.2 toolchain"; exit 1; }
"$SWIFT" sdk list 2>/dev/null | grep -q static-linux || { print -u2 "no Static Linux SDK for $SWIFT"; exit 1; }
command -v xz >/dev/null || { print -u2 "needs xz (brew install xz)"; exit 1; }
mkdir -p "$OUT"

for arch in $archs; do
    [[ $arch == (x86_64|aarch64) ]] || { print -u2 "unknown arch $arch: x86_64 or aarch64"; exit 1; }
    linux=(--swift-sdk "$arch-swift-linux-musl" -c release --product kore-host --scratch-path .build-linux)
    "$SWIFT" build "${linux[@]}" -Xlinker --strip-all
    xz -9 -T0 -c "$("$SWIFT" build "${linux[@]}" --show-bin-path)/kore-host" > "$OUT/kore-host-linux-$arch.xz"
    echo "built $OUT/kore-host-linux-$arch.xz ($(( $(stat -f %z "$OUT/kore-host-linux-$arch.xz") / 1024 )) KB)"
done

# kore-tailnet (phase 18), the Go tsnet sidecar for boxes without tailscaled, for the same CPUs.
# Skipped with a note when Go isn't installed; release.sh attaches whichever were built.
scripts/build-tailnet.sh linux-${^archs}
