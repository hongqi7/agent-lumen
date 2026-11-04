#!/bin/bash
# Build "Agent Lumen.app" (universal: Apple silicon + Intel) and a release zip.
#   ./build.sh            -> build/Agent Lumen.app, build/AgentLumen-<version>.zip
#   ./build.sh install    -> also copy the app to /Applications and open it
set -euo pipefail

VERSION="1.9.4"
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/build"
APP="$BUILD/Agent Lumen.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
        -o "$BUILD/AgentLumen-$arch" "$HERE/Sources/AgentLumen.swift"
done
lipo -create -output "$APP/Contents/MacOS/AgentLumen" "$BUILD/AgentLumen-arm64" "$BUILD/AgentLumen-x86_64"
rm -f "$BUILD"/AgentLumen-arm64 "$BUILD"/AgentLumen-x86_64

cp "$HERE/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp "$HERE/Resources/lumen-hook" "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/lumen-hook"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.hongqi7.agent-lumen</string>
    <key>CFBundleName</key><string>Agent Lumen</string>
    <key>CFBundleDisplayName</key><string>Agent Lumen</string>
    <key>CFBundleExecutable</key><string>AgentLumen</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"

ZIP="$BUILD/AgentLumen-$VERSION.zip"
rm -f "$ZIP"
(cd "$BUILD" && ditto -c -k --keepParent "Agent Lumen.app" "$ZIP")
echo "built: $APP"
echo "zip:   $ZIP"

if [ "${1:-}" = "install" ]; then
    # SIGTERM lets the app hand the keyboard lights back. Wait for it: a second copy opened too early exits on its own
    pkill -x AgentLumen 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x AgentLumen >/dev/null || break; sleep 0.2; done
    pkill -9 -x AgentLumen 2>/dev/null || true
    rm -rf "/Applications/Agent Lumen.app"
    cp -R "$APP" /Applications/
    # macOS ties Input Monitoring to the signature, and an ad-hoc one changes with every build. Signing the
    # local copy with your own development certificate keeps the grant across rebuilds. The release zip
    # stays ad-hoc, since a personal certificate would carry your name and email inside the app.
    IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
    if [ -n "$IDENTITY" ]; then
        codesign --force --sign "$IDENTITY" "/Applications/Agent Lumen.app" && echo "signed with: $IDENTITY"
    fi
    open "/Applications/Agent Lumen.app"
    echo "installed: /Applications/Agent Lumen.app"
fi
