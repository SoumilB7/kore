#!/bin/zsh
# Builds Kore.app and packs it into build/Kore-<version>.dmg: the app beside a link to
# /Applications, so installing is one drag. Writes the DMG's SHA-256 next to it.
set -euo pipefail

cd "${0:A:h}/.."
VERSION="$(<VERSION)"
DMG="build/Kore-$VERSION.dmg"
STAGE="build/dmg"

./scripts/build-app.sh

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto build/Kore.app "$STAGE/Kore.app"
ln -s /Applications "$STAGE/Applications"
cp build/Kore.app/Contents/Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"

# Made writable first: the volume's custom-icon flag only sticks when set on the mounted volume.
RW="build/Kore-rw.dmg"
hdiutil create -quiet -volname "Kore $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
rm -rf "$STAGE"
MNT="$(mktemp -d)"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MNT" "$RW"
SetFile -a C "$MNT"
hdiutil detach -quiet "$MNT"
rmdir "$MNT"
hdiutil convert -quiet "$RW" -format UDZO -o "$DMG"
rm -f "$RW"
codesign --force --sign - "$DMG"

shasum -a 256 "$DMG" | sed 's| build/| |' > "$DMG.sha256"
echo "built $DMG"
cat "$DMG.sha256"
