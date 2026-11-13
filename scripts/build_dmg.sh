#!/bin/bash
# Build a distributable Keystrike.dmg from scripts/build_app.sh's output.
#
#   scripts/build_dmg.sh [debug|release]
#
# Keystrike is a SwiftPM project with no Xcode workspace, so the .app is
# assembled by hand (see build_app.sh) and wrapped here. The DMG holds the app
# plus an Applications symlink, so a user can drag it straight into
# /Applications - the layout Finder uses for "normal" downloads.
set -euo pipefail

configuration="${1:-release}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

case "$configuration" in
    debug|release) ;;
    *) echo "usage: scripts/build_dmg.sh [debug|release]" >&2; exit 2 ;;
esac

# 1. build (and ad-hoc sign) the .app
bash scripts/build_app.sh "$configuration" >/dev/null
app="$root/.build/$configuration/Keystrike.app"
[[ -d "$app" ]] || { echo "[dmg] missing $app" >&2; exit 1; }

# 2. stage: the app + a symlink to /Applications
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$app/Contents/Info.plist" 2>/dev/null || echo 1.0)"
name="Keystrike"
out="$root/.build/dmg/$name-$version.dmg"
staging="$root/.build/dmg/staging"

rm -rf "$root/.build/dmg"
mkdir -p "$staging"
cp -R "$app" "$staging/$name.app"
ln -s /Applications "$staging/Applications"

# 3. write the image (read-only, zlib compressed: the standard shape)
echo "[dmg] creating $out"
hdiutil create "$out" \
    -volname "$name" \
    -srcfolder "$staging" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    -quiet

# 4. sanity: the image must mount, contain the app, and verify its checksum
echo "[dmg] verifying"
hdiutil verify "$out" >/dev/null
mnt="$(diskutil image attach --mountOptions nobrowse --readOnly "$out" \
        | awk '/\/Volumes\// {print $3; exit}')"
found="$(ls -d "$mnt/$name.app" 2>/dev/null || true)"
diskutil image detach "$mnt" >/dev/null 2>&1 || true
[[ -n "$found" ]] || { echo "[dmg] app missing from image" >&2; exit 1; }

echo "[dmg] $(du -h "$out" | awk '{print $1}')  $out"
