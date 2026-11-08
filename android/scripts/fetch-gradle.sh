#!/bin/zsh
# Fetches the pinned Gradle distribution into GRADLE_USER_HOME once, checking the SHA-256 that
# gradle/wrapper/gradle-wrapper.properties pins. Nothing else downloads Gradle.
set -eu
export KORE_ANDROID="${0:A:h:h}"
source "$KORE_ANDROID/scripts/env.sh"
props="$KORE_ANDROID/gradle/wrapper/gradle-wrapper.properties"
url=$(sed -n 's/^distributionUrl=//p' "$props" | sed 's/\\:/:/')
sum=$(sed -n 's/^distributionSha256Sum=//p' "$props")
version=$(print -r -- "$url" | sed -n 's/.*gradle-\(.*\)-bin\.zip$/\1/p')
dest="$GRADLE_USER_HOME/wrapper/dists/gradle-$version-bin/kore"
[[ -x "$dest/gradle-$version/bin/gradle" ]] && { print "gradle $version already here"; exit 0; }
mkdir -p "$dest"
curl -fsSL "$url" -o "$dest/gradle.zip"
print "$sum  $dest/gradle.zip" | shasum -a 256 -c - >/dev/null
unzip -q "$dest/gradle.zip" -d "$dest" && rm "$dest/gradle.zip"
print "gradle $version in $dest"
