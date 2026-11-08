#!/bin/zsh
# Builds Kore.app into build/. With --install, also copies it to /Applications.
set -euo pipefail

cd "${0:A:h}/.."
VERSION="$(<VERSION)"
# The commit built, for scripts/check-install.sh; a copy without .git (the verify cache) passes it in.
BUILD_SHA="${KORE_BUILD_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
APP="build/Kore.app"

swift build -c release --product Kore
swift build -c release --product kore-command
BIN="$(swift build -c release --show-bin-path)/Kore"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kore"
# The `kore` command: the binary reads Kore over its agent channel and hands opening and setup
# to the script. Resources/kore stays where ~/.local/bin/kore has always pointed.
cp "${BIN:h}/kore-command" "$APP/Contents/Helpers/kore"
cp scripts/kore "$APP/Contents/Resources/kore.zsh"
ln -s ../Helpers/kore "$APP/Contents/Resources/kore"
cp -R Resources/ThirdParty "$APP/Contents/Resources/ThirdParty"
# The package's resource bundles (mermaid.js).
cp -R "${BIN:h}"/*.bundle "$APP/Contents/Resources/"

# kore-host for Linux boxes, which Set up in the Boxes panel copies over SSH: static (musl) builds
# for x86_64 and aarch64, packed with xz. They need a swift.org toolchain with its Static Linux SDK
# (`swift sdk install …static-linux…`); without one, or with KORE_NO_BOX_HOST=1, the app is built
# without them and Set up says so.
LINUX_SWIFT="${KORE_LINUX_SWIFT:-$HOME/Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain/usr/bin/swift}"
if [[ -n "${KORE_NO_BOX_HOST:-}" ]]; then
    echo "kore-host for boxes: skipped (KORE_NO_BOX_HOST)"
elif [[ ! -x "$LINUX_SWIFT" ]] || ! "$LINUX_SWIFT" sdk list 2>/dev/null | grep -q static-linux || ! command -v xz >/dev/null; then
    echo "kore-host for boxes: skipped (needs $LINUX_SWIFT with the Static Linux SDK, and xz)" >&2
else
    for arch in x86_64 aarch64; do
        linux=(--swift-sdk "$arch-swift-linux-musl" -c release --product kore-host --scratch-path .build-linux)
        "$LINUX_SWIFT" build "${linux[@]}" -Xlinker --strip-all
        xz -9 -T0 -c "$("$LINUX_SWIFT" build "${linux[@]}" --show-bin-path)/kore-host" > "$APP/Contents/Resources/kore-host-linux-$arch.xz"
    done
fi

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
    <key>CFBundleName</key><string>Kore</string>
    <key>CFBundleDisplayName</key><string>Kore</string>
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

# Ad-hoc signature: enough to run locally. Not sandboxed, since it must spawn `claude`.
codesign --force --options runtime --sign - "$APP/Contents/Helpers/kore"
codesign --force --options runtime --sign - "$APP"
echo "built $APP ($BUILD_SHA)"

if [[ "${1:-}" == "--install" ]]; then
    osascript -e 'quit app "Kore"' 2>/dev/null || true
    # Kore asks first while chats work: replace it only once it has really quit, never under a
    # running app (a cancelled quit would leave it running from a deleted bundle).
    for _ in {1..60}; do
        pgrep -f '^/Applications/Kore.app/Contents/MacOS/Kore' >/dev/null || break
        sleep 1
    done
    if pgrep -f '^/Applications/Kore.app/Contents/MacOS/Kore' >/dev/null; then
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
