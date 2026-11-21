#!/bin/zsh
# scripts/build-app.sh [--dev] [--install]
# Builds Kore.app into build/. With --install, also copies it to /Applications.
#
# --dev builds Kore Dev instead: build/Kore Dev.app, bundle id dev.kore.KoreDev, binary "Kore Dev",
# an amber icon. It keeps its own settings (the dev.kore.KoreDev domain) and its own Application
# Support, Logs and Caches folders ("Kore Dev": agent socket, link, KoreNet identity, logs), never
# checks for updates, and shows as "Kore Dev" in Battery and Activity Monitor, so a dev build is
# never taken for the owner's Kore. --dev --install puts it in ~/Applications. Releases
# (install.sh, release.sh) build Kore. docs/dev-builds.md.
set -euo pipefail

cd "${0:A:h}/.."
DEV=""; INSTALL=""
for arg in "$@"; do
    case $arg in
        --dev) DEV=1 ;;
        --install) INSTALL=1 ;;
        *) print -u2 "usage: scripts/build-app.sh [--dev] [--install]"; exit 2 ;;
    esac
done
VERSION="$(<VERSION)"
# The commit built, for scripts/check-install.sh; a copy without .git (the verify cache) passes it in.
BUILD_SHA="${KORE_BUILD_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
if [[ -n $DEV ]]; then
    NAME="Kore Dev"; BUNDLE_ID=dev.kore.KoreDev; INSTALLED="$HOME/Applications/Kore Dev.app"
else
    NAME="Kore"; BUNDLE_ID=dev.kore.Kore; INSTALLED=/Applications/Kore.app
fi
APP="build/$NAME.app"

swift build -c release --product Kore
swift build -c release --product kore-command
BIN="$(swift build -c release --show-bin-path)/Kore"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
# The `kore` command: the binary reads Kore over its agent channel and hands opening and setup
# to the script. Resources/kore stays where ~/.local/bin/kore has always pointed.
cp "${BIN:h}/kore-command" "$APP/Contents/Helpers/kore"
cp scripts/kore "$APP/Contents/Resources/kore.zsh"
ln -s ../Helpers/kore "$APP/Contents/Resources/kore"
cp -R Resources/ThirdParty "$APP/Contents/Resources/ThirdParty"
# The package's resource bundles (mermaid.js).
cp -R "${BIN:h}"/*.bundle "$APP/Contents/Resources/"

# kore-host isn't built here: box Set up builds it on this Mac from the same source, when first needed.

# Kore's own tailnet helper (KoreNet without installed Tailscale): built from source with Go, else
# the release's, checked against its signed SHA256SUMS (scripts/tailnet-helper.sh), signed there.
# Without it KoreNet offers SSH only, and the build goes on either way.
scripts/tailnet-helper.sh "$APP/Contents/Helpers/kore-tailnet" || echo "note: Kore.app ships without kore-tailnet"

# App icon, rendered from the SVGs in Resources/.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
if [[ -n $DEV ]]; then
    # Kore Dev's: the same mark in amber.
    for svg in AppIcon AppIcon-small; do
        sed -e 's/#6AB1E7/#F2B266/g; s/#3C97DD/#E8913A/g; s/#257DC1/#C97222/g; s/#1B6298/#9A5418/g; s/#BED7EB/#EBD3BE/g' \
            Resources/$svg.svg > build/$svg-dev.svg
    done
    swift scripts/render-icon.swift build/AppIcon-dev.svg "$ICONSET" build/AppIcon-small-dev.svg
else
    swift scripts/render-icon.swift Resources/AppIcon.svg "$ICONSET" Resources/AppIcon-small.svg
fi
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>KoreBuild</key><string>$BUILD_SHA</string>
    <key>KoreSourceCommit</key><string>${KORE_SOURCE_COMMIT:-$(git rev-parse HEAD 2>/dev/null)}</string>
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

# Ad-hoc signature: enough to run locally. Not sandboxed, since it must spawn `claude`.
# KORE_SIGN_IDENTITY (an install on this Mac: its own certificate, scripts/local-sign.sh):
# the same signer every build, so what macOS keyed to Kore (the Keychain's Always Allow for
# KoreNet's identity, privacy permissions) holds across builds. An ad-hoc build is a new app
# to macOS each time and asks again.
sign=${KORE_SIGN_IDENTITY:--}
signed() { codesign --force --options runtime --sign "$1" "$APP/Contents/Helpers/kore" && codesign --force --options runtime --sign "$1" "$APP" }
if ! signed "$sign"; then
    # The identity couldn't sign (its key refused, the certificate gone): a build ad-hoc rather than none.
    [[ $sign != - ]] || exit 1
    echo "couldn't sign with \"$sign\": signed ad-hoc instead"
    signed -
fi
echo "built $APP ($BUILD_SHA)"

if [[ -n $INSTALL && -n $DEV ]]; then
    # Kore Dev beside the owner's Kore, never over it.
    if pgrep -af "^$INSTALLED/Contents/MacOS/" >/dev/null; then osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || true; fi
    for _ in {1..30}; do pgrep -af "^$INSTALLED/Contents/MacOS/" >/dev/null || break; sleep 1; done
    if pgrep -af "^$INSTALLED/Contents/MacOS/" >/dev/null; then echo "Kore Dev is still running: not installed. $APP is built." >&2; exit 1; fi
    mkdir -p ~/Applications
    rm -rf ~/"Applications/Kore Dev.app"
    ditto "$APP" "$INSTALLED"
    echo "installed $INSTALLED"
elif [[ -n $INSTALL ]]; then
    osascript -e 'quit app "Kore"' 2>/dev/null || true
    # Kore asks first while chats work: replace it only once it has really quit, never under a
    # running app (a cancelled quit would leave it running from a deleted bundle). -a: started
    # from Kore (its update, its terminal), Kore is an ancestor, which pgrep otherwise skips.
    for _ in {1..60}; do
        pgrep -af '^/Applications/Kore.app/Contents/MacOS/Kore' >/dev/null || break
        sleep 1
    done
    if pgrep -af '^/Applications/Kore.app/Contents/MacOS/Kore' >/dev/null; then
        echo "Kore is still running (quit cancelled?): not installed. $APP is built." >&2
        exit 1
    fi
    rm -rf /Applications/Kore.app
    ditto "$APP" /Applications/Kore.app
    echo "installed /Applications/Kore.app"
    # The `kore` command: `kore` opens Kore, `kore <folder>` opens that folder, `kore setup` installs the CLIs.
    mkdir -p ~/.local/bin
    ln -sf /Applications/Kore.app/Contents/Resources/kore ~/.local/bin/kore
    echo "linked ~/.local/bin/kore"
fi
