#!/bin/zsh
# Builds Kore.app into build/. With --install, also copies it to /Applications.
#
# KORE_FLAVOR=lite (the default) builds Kore; KORE_FLAVOR=phone builds Kore Phone, the same app
# with the phone remote. Both are dev.kore.Kore: installing one replaces the other.
set -euo pipefail

cd "${0:A:h}/.."
VERSION="$(<VERSION)"
# The commit built, for scripts/check-install.sh; a copy without .git (the verify cache) passes it in.
BUILD_SHA="${KORE_BUILD_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
FLAVOR="${KORE_FLAVOR:-lite}"
case $FLAVOR in
    lite) PRODUCT=Kore; NAME=Kore ;;
    phone) PRODUCT=kore-phone; NAME="Kore Phone" ;;
    *) echo "KORE_FLAVOR is lite or phone" >&2; exit 2 ;;
esac
APP="build/$NAME.app"

swift build -c release --product "$PRODUCT"
BIN="$(swift build -c release --show-bin-path)/$PRODUCT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kore"
cp scripts/kore "$APP/Contents/Resources/kore"
cp -R Resources/ThirdParty "$APP/Contents/Resources/ThirdParty"
# The package's resource bundles (mermaid.js).
cp -R "${BIN:h}"/*.bundle "$APP/Contents/Resources/"

# App icon, rendered from the SVGs in Resources/.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/render-icon.swift Resources/AppIcon.svg "$ICONSET" Resources/AppIcon-small.svg
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Kore</string>
    <key>CFBundleIdentifier</key><string>dev.kore.Kore</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>KoreFlavor</key><string>$FLAVOR</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>KoreBuild</key><string>$BUILD_SHA</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>None</string>
            <key>LSItemContentTypes</key><array><string>public.folder</string></array>
        </dict>
    </array>
</dict>
</plist>
EOF

# Ad-hoc, with the hardened runtime (no injected libraries, no debugger attaching). Not
# sandboxed, since it must spawn `claude`.
codesign --force --options runtime --sign - "$APP"
echo "built $APP ($BUILD_SHA, $FLAVOR)"

if [[ "${1:-}" == "--install" ]]; then
    osascript -e 'quit app id "dev.kore.Kore"' 2>/dev/null || true
    # Kore asks first while chats work: replace it only once it has really quit, never under a
    # running app (a cancelled quit would leave it running from a deleted bundle).
    for _ in {1..60}; do
        pgrep -f '^/Applications/Kore( Phone)?.app/Contents/MacOS/Kore' >/dev/null || break
        sleep 1
    done
    if pgrep -f '^/Applications/Kore( Phone)?.app/Contents/MacOS/Kore' >/dev/null; then
        echo "Kore is still running (quit cancelled?): not installed. $APP is built." >&2
        exit 1
    fi
    # One edition at a time: they're the same app.
    rm -rf /Applications/Kore.app "/Applications/Kore Phone.app"
    ditto "$APP" "/Applications/$NAME.app"
    echo "installed /Applications/$NAME.app"
    # The `kore` command: `kore` opens Kore, `kore <folder>` opens that folder, `kore setup` installs the CLIs.
    mkdir -p ~/.local/bin
    ln -sf "/Applications/$NAME.app/Contents/Resources/kore" ~/.local/bin/kore
    echo "linked ~/.local/bin/kore"
fi
