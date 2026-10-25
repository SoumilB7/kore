#!/bin/zsh
# Retakes the README's screenshots: plays the `readme` storylines (scripted CLI, demo folders,
# emails masked) and frames each shot into docs/images. Needs Pillow for the framing.
set -euo pipefail
cd "${0:A:h}/.."
out="${TMPDIR:-/tmp}/kore-readme-shots"
rm -rf "$out"
./scripts/storylines.sh --tag readme --out "$out"
python3 scripts/frame-shots.py "$out" docs/images accounts flow port board
ls -l docs/images
