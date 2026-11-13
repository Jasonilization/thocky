#!/bin/bash
# Assemble Thocky.app from `swift build`.
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
executable="$root/.build/$configuration/thocky"
[[ -x "$executable" ]] || { echo "[build] missing executable: $executable" >&2; exit 1; }

app="$products/Thocky.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

# C targets are linked statically, so nothing from .build/ needs shipping.
cp "$executable" "$app/Contents/MacOS/Thocky"
cp -R "$root/Resources/Packs" "$app/Contents/Resources/Packs"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>Thocky</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.thocky.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Thocky</string>
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

if [[ ! -f "$root/Resources/AppIcon.icns" ]]; then
    swift "$root/scripts/render_branding.swift" "$root"
fi
if [[ -f "$root/Resources/AppIcon.icns" ]]; then
    cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
fi

# Prefer a real (local development) signing identity over ad-hoc: with an
# identity, macOS keeps the user's Accessibility grant when you rebuild, because
# the grant follows the signing certificate instead of the binary's hash. Ad-hoc
# signing changes that hash on every build, which is why Accessibility had to be
# re-granted by hand.
SIGN_ID="${THOCKY_SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
              | grep -o '[0-9A-F]\{40\}' | head -1 || true)
fi
if [[ -n "$SIGN_ID" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "[codesign] identity $SIGN_ID"
    codesign --force --sign "$SIGN_ID" \
        --identifier com.thocky.app \
        --entitlements "$root/Resources/Thocky.entitlements" \
        "$app" 2>&1 | sed 's/^/[codesign] /' || true
else
    echo "[codesign] ad-hoc (no codesigning identity found; set THOCKY_SIGN_ID for stable Accessibility grants)"
    codesign --force --sign - \
        --identifier com.thocky.app \
        --entitlements "$root/Resources/Thocky.entitlements" \
        "$app" 2>&1 | sed 's/^/[codesign] /' || true
fi

echo "[build] $app"
