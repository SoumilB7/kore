#!/bin/zsh
# Puts a phone build where Kore on this Mac offers it to its phones over KoreNet ("Update ready ·
# from <Mac>", link 1.13 app.get): ~/Library/Application Support/Kore/phone-app/.
#   offer-to-phone.sh <release dir>   a release's kore.apk, SHA256SUMS and SHA256SUMS.sig (release.sh's output)
#   offer-to-phone.sh <apk> <version> a dev build: an unsigned SHA256SUMS, taken only by a debug app,
#                                     and only over the same signing key (Android's rule)
set -eu
dest="$HOME/Library/Application Support/Kore/phone-app"
mkdir -p "$dest"
if [[ -d "$1" ]]; then
  for f in kore.apk SHA256SUMS SHA256SUMS.sig; do [[ -f "$1/$f" ]] || { print "no $f in $1"; exit 2; }; done
  cp "$1/kore.apk" "$1/SHA256SUMS" "$1/SHA256SUMS.sig" "$dest/"
else
  [[ $# -eq 2 ]] || { print "usage: offer-to-phone.sh <release dir> | <apk> <version>"; exit 2; }
  cp "$1" "$dest/kore.apk"
  sha=$(shasum -a 256 "$dest/kore.apk" | awk '{print $1}')
  commit=$(git -C "${0:A:h}" rev-parse HEAD)
  print -r -- "# kore $2 $commit"$'\n'"$sha  kore.apk" > "$dest/SHA256SUMS"
  rm -f "$dest/SHA256SUMS.sig"
fi
ls -l "$dest"
