#!/bin/zsh
# Builds Kore.app into build/. With --install, also copies it to /Applications.
set -euo pipefail

cd "${0:A:h}/.."
VERSION="0.1.0"
APP="build/Kore.app"

swift build -c release --product Kore
BIN="$(swift build -c release --show-bin-path)/Kore"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kore"

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
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

# Ad-hoc signature: enough to run locally. Not sandboxed, since it must spawn `claude`.
codesign --force --sign - "$APP"
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
    osascript -e 'quit app "Kore"' 2>/dev/null || true
    rm -rf /Applications/Kore.app
    ditto "$APP" /Applications/Kore.app
    echo "installed /Applications/Kore.app"
fi
