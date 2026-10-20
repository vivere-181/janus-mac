#!/bin/zsh
# Publishes a Mac release on GitHub (vivere-181/janus-mac): builds and packages (dmg for first installs, zip for in-app
# updates), exports and pushes the source with tag v<ui/VERSION>, and creates the release with both attached.
# Run it yourself: it publishes.
#   tools/release.sh notes.md      (release notes in Markdown; bump ui/VERSION first)
# The tag is pushed with git rather than made by GitHub's API, which needs the "workflow" scope for a commit that
# contains .github/workflows.
set -e
M=${0:A:h:h}
NOTES=${1:?usage: tools/release.sh <notes.md>}
VERSION=$(tr -d '[:space:]' < "$M/ui/VERSION")
REPO=${JANUS_MAC_REPO:-vivere-181/janus-mac}
CLONE=${JANUS_MAC_CLONE:-$HOME/Janus/janus-mac}

"$M/tools/package.sh"
OUT="$M/build.noindex/dist"

"$M/tools/export-public.sh" "${REPO%%/*}" "$CLONE"
git -C "$CLONE" add -A
git -C "$CLONE" diff --cached --quiet || git -C "$CLONE" commit -q -m "Janus $VERSION"
git -C "$CLONE" tag -a "v$VERSION" -m "Janus $VERSION"
git -C "$CLONE" push -q origin HEAD "v$VERSION"

echo "Publishing Janus $VERSION to $REPO…"
gh release create "v$VERSION" "$OUT/Janus-$VERSION.dmg" "$OUT/Janus-$VERSION.zip" \
  --repo "$REPO" --title "Janus $VERSION" --notes-file "$NOTES" --verify-tag
echo "Done: https://github.com/$REPO/releases/tag/v$VERSION"
