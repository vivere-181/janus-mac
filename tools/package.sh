#!/bin/zsh
# Makes the release files: build.noindex/dist/Janus-<version>.dmg (drag Janus into Applications; first installs)
# and Janus-<version>.zip (what in-app updates download). Built and signed like an install; the installed app isn't
# touched.
#   tools/package.sh   (from the repository folder)
set -e
M=${0:A:h:h}
OUT="$M/build.noindex/dist"
IMAGE="$OUT/image"
VERSION=$(tr -d '[:space:]' < "$M/ui/VERSION")

"$M/tools/build-ui.sh"
rm -rf "$OUT"; mkdir -p "$IMAGE"
ditto "$M/build.noindex/Janus.app" "$IMAGE/Janus.app"
"$M/tools/sign.sh" "$IMAGE/Janus.app" | sed 's/^/  /'
ln -s /Applications "$IMAGE/Applications"
hdiutil create -quiet -volname "Janus" -srcfolder "$IMAGE" -ov -format UDZO "$OUT/Janus-$VERSION.dmg"
ditto -c -k --sequesterRsrc --keepParent "$IMAGE/Janus.app" "$OUT/Janus-$VERSION.zip"
rm -rf "$IMAGE"
echo "Installer: $OUT/Janus-$VERSION.dmg ($(du -h "$OUT/Janus-$VERSION.dmg" | cut -f1))"
echo "Update:    $OUT/Janus-$VERSION.zip ($(du -h "$OUT/Janus-$VERSION.zip" | cut -f1))"
