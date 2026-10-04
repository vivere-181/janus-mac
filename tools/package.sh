#!/bin/zsh
# Makes an installer for another Mac: build.noindex/dist/Janus-<date>.dmg (drag Janus into Applications).
# The engine comes from this Mac's installed /Applications/Janus.app; the interface from the latest build.
# The installed app isn't touched.
#   tools/package.sh   (from the repository folder)
set -e
M=${0:A:h:h}
INSTALLED=/Applications/Janus.app
OUT="$M/build.noindex/dist"
IMAGE="$OUT/image"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -d "$INSTALLED/Contents/Library/Engine" ]] || { echo "Install the app on this Mac first (apply.sh)."; exit 1; }

"$M/tools/build-ui.sh"
rm -rf "$OUT"; mkdir -p "$IMAGE"
ditto "$INSTALLED" "$IMAGE/Janus.app"
# apply.sh on the copy: fresh interface, engine set up, signed (FRESH: never pick up a KDE Connect download).
TARGET="$IMAGE/Janus.app" FRESH="$OUT/none" "$M/apply.sh" | sed 's/^/  /'
ln -s /Applications "$IMAGE/Applications"
VERSION=$(date +%Y.%m.%d)
hdiutil create -quiet -volname "Janus" -srcfolder "$IMAGE" -ov -format UDZO "$OUT/Janus-$VERSION.dmg"
# apply.sh registered the copy with Launch Services; forget it again.
$LSR -u "$IMAGE/Janus.app" 2>/dev/null || true
rm -rf "$IMAGE"
$LSR -f "$INSTALLED" 2>/dev/null || true
echo "Installer: $OUT/Janus-$VERSION.dmg ($(du -h "$OUT/Janus-$VERSION.dmg" | cut -f1))"
