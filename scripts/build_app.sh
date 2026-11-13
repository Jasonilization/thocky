#!/bin/bash
# Assemble Keystrike.app from `swift build`.
#
#   scripts/build_app.sh [debug|release]
#
# There is no Xcode project: SwiftPM builds the executable, and this script
# wraps it in a minimal .app bundle (Info.plist + Resources) and ad-hoc
# codesigns it so macOS will run it without an "unidentified developer" dialog
# when Accessibility access is granted to it.
set -euo pipefail

configuration="${1:-debug}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

case "$configuration" in
    debug|release) ;;
    *) echo "usage: scripts/build_app.sh [debug|release]" >&2; exit 2 ;;
esac

echo "[build] swift build -c $configuration"
swift build -c "$configuration" 2>&1 | tail -5

products="$root/.build/app/$configuration"
executable="$root/.build/$configuration/keystrike"
[[ -x "$executable" ]] || { echo "[build] missing executable: $executable" >&2; exit 1; }

app="$products/Keystrike.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

# C targets are linked statically, so nothing from .build/ needs shipping.
cp "$executable" "$app/Contents/MacOS/Keystrike"
cp -R "$root/Resources/Packs" "$app/Contents/Resources/Packs"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>Keystrike</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.keystrike.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Keystrike</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

if [[ -f "$root/Resources/AppIcon.icns" ]]; then
    cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - \
    --identifier com.keystrike.app \
    --entitlements "$root/Resources/Keystrike.entitlements" \
    "$app" 2>&1 | sed 's/^/[codesign] /' || true

echo "[build] $app"
