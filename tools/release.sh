#!/bin/zsh
# Publishes a Mac release on GitHub (vivere-181/janus-mac): builds, packages (dmg for first installs, zip for in-app
# updates), and creates release v<ui/VERSION> with both attached. Run it yourself: it publishes.
#   tools/release.sh notes.md      (release notes in Markdown; bump ui/VERSION first)
set -e
M=${0:A:h:h}
NOTES=${1:?usage: tools/release.sh <notes.md>}
VERSION=$(tr -d '[:space:]' < "$M/ui/VERSION")
REPO=${JANUS_MAC_REPO:-vivere-181/janus-mac}
"$M/tools/package.sh"
OUT="$M/build.noindex/dist"
echo "Publishing Janus $VERSION to $REPO…"
gh release create "v$VERSION" "$OUT/Janus-$VERSION.dmg" "$OUT/Janus-$VERSION.zip" \
  --repo "$REPO" --title "Janus $VERSION" --notes-file "$NOTES"
echo "Done: https://github.com/$REPO/releases/tag/v$VERSION"
