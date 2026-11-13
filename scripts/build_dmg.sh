#!/bin/bash
# Build a drag-to-install Thocky.dmg.
#
#   scripts/build_dmg.sh [debug|release]
#
# The image is a Finder window: Thocky on the left, Applications on the right,
# a background with an arrow between them. Layout is applied with Finder, then
# the image is compressed and checked by mounting it again.
set -euo pipefail

configuration="${1:-release}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

case "$configuration" in
    debug|release) ;;
    *) echo "usage: scripts/build_dmg.sh [debug|release]" >&2; exit 2 ;;
esac

echo "[dmg] drawing icon and background"
swift "$root/scripts/render_branding.swift" "$root"

bash "$root/scripts/build_app.sh" "$configuration" >/dev/null
app="$root/.build/app/$configuration/Thocky.app"
[[ -d "$app" ]] || { echo "[dmg] missing $app" >&2; exit 1; }

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$app/Contents/Info.plist" 2>/dev/null || echo 1.0)"
name="Thocky"
out="$root/.build/dmg/$name-$version.dmg"
work="$root/.build/dmg/work"
rw="$work/$name-rw.dmg"

rm -rf "$root/.build/dmg"
mkdir -p "$work"

# Room for the app plus Finder's .DS_Store and the background.
bytes=$(du -sm "$app" | awk '{print $1}')
megs=$((bytes + 24))

echo "[dmg] creating writable image (${megs}m)"
hdiutil create -size "${megs}m" -fs HFS+ -volname "$name" -ov "$rw" >/dev/null

mount=$(hdiutil attach -readwrite -noverify -noautoopen "$rw" | grep -o '/Volumes/.*' | head -1)
[[ -n "$mount" ]] || { echo "[dmg] attach failed" >&2; exit 1; }
cleanup() { hdiutil detach "$mount" >/dev/null 2>&1 || hdiutil detach -force "$mount" >/dev/null 2>&1 || true; }
trap cleanup EXIT

cp -R "$app" "$mount/$name.app"
ln -s /Applications "$mount/Applications"
mkdir -p "$mount/.background"
cp "$root/Resources/dmg-background.png" "$mount/.background/background.png"
if [[ -f "$root/Resources/AppIcon.icns" ]]; then
    cp "$root/Resources/AppIcon.icns" "$mount/.VolumeIcon.icns"
    # Custom-icon bit. SetFile ships with the command-line tools; skip if absent.
    if command -v SetFile >/dev/null 2>&1; then
        SetFile -a C "$mount" || true
    fi
fi
# Hide the background folder only after Finder has accepted the picture.
# Hiding it first makes "set background picture" fail with -10006.

echo "[dmg] laying out the window"
styled=0
if osascript - "$mount" "$name" <<'EOF'
on run argv
    set mountPath to item 1 of argv
    set volName to item 2 of argv
    tell application "Finder"
        activate
        tell disk volName
            open
            delay 1
            set cw to container window
            set current view of cw to icon view
            set toolbar visible of cw to false
            set statusbar visible of cw to false
            set the bounds of cw to {240, 120, 920, 548}
            set viewOptions to the icon view options of cw
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 120
            set text size of viewOptions to 13
            set background picture of viewOptions to POSIX file (mountPath & "/.background/background.png")
            set theApp to item (volName & ".app") of cw
            set extension hidden of theApp to true
            set position of theApp to {160, 210}
            set position of item "Applications" of cw to {500, 210}
            -- Leave the window open. Closing it before detach writes a
            -- .DS_Store that drops icon size and arrangement; unmounting
            -- while the window is open keeps both.
            delay 1
        end tell
    end tell
end run
EOF
then
    styled=1
    chflags hidden "$mount/.background" || true
else
    echo "[dmg] Finder layout was skipped; the image still contains the app and Applications" >&2
    chflags hidden "$mount/.background" || true
fi

sync
trap - EXIT
hdiutil detach "$mount" >/dev/null 2>&1 || hdiutil detach -force "$mount" >/dev/null 2>&1

echo "[dmg] compressing"
rm -f "$out"
hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -o "$out" >/dev/null
rm -rf "$work"

echo "[dmg] verifying"
hdiutil verify "$out" >/dev/null
check=$(hdiutil attach -readonly -noverify -noautoopen "$out" | grep -o '/Volumes/.*' | head -1)
found="$(ls -d "$check/$name.app" "$check/Applications" 2>/dev/null || true)"
hdiutil detach "$check" >/dev/null 2>&1 || true
[[ -n "$found" ]] || { echo "[dmg] app missing from image" >&2; exit 1; }

echo "[dmg] $(du -h "$out" | awk '{print $1}')  $out"
