#!/bin/zsh
# Copies the public parts of this workspace into a separate git repository for GitHub (default ~/Janus/janus-mac),
# then checks it for personal data. The working folder keeps everything private (notes between the two apps'
# developers, backups, builds); only what's listed here is published.
#   tools/export-public.sh <github-username> [destination]
set -e
M=${0:A:h:h}
GH_USER=${1:?usage: tools/export-public.sh <github-username> [destination]}
DEST=${2:-$HOME/Janus/janus-mac}
mkdir -p "$DEST"

# Start from an empty tree (keeping the destination's own .git), then copy the public files.
find "$DEST" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
copy() {
  local src=$1 dst=${2:-$1}
  if [[ $src == */ ]]; then mkdir -p "$DEST/$dst"; else mkdir -p "$DEST/${dst:h}"; fi
  rsync -a --exclude .DS_Store --exclude .build "$M/$src" "$DEST/$dst"
}
copy apply.sh
copy ui/Package.swift
copy ui/Sources/
copy ui/ShareExtension/
copy ui/WidgetExtension/
copy tools/build-ui.sh
copy tools/package.sh
copy tools/sign.sh
copy tools/release.sh
copy ui/VERSION
copy ui/Tests/
copy tools/snap.swift
copy tools/export-public.sh
copy assets/Janus.icon/
copy assets/JanusDark.icon/
copy assets/Colors.xcassets/
copy assets/menubar-janus.svg
copy assets/scrcpy/scrcpy-server-v4.1
copy release-docs/README.md README.md
copy release-docs/CREDITS.md CREDITS.md
copy release-docs/LICENSE LICENSE
copy release-docs/LICENSES/ LICENSES/
copy release-docs/gitignore .gitignore
copy release-docs/.github/ .github/
copy release-docs/PROTOCOL.md docs/PROTOCOL.md
grep -rl "OWNER" "$DEST" --include='*.md' | while read f; do sed -i '' "s/OWNER/$GH_USER/g" "$f"; done

# Nothing personal may leave: names, contact details, paths, device ids, real-life test data. The patterns live in a
# private file (one regular expression per line) that is never exported.
PRIVATE=${JANUS_PRIVATE_PATTERNS:-$M/shared/private-patterns.txt}
[[ -f "$PRIVATE" ]] || { echo "✗ No private patterns file ($PRIVATE): can't check the export."; exit 1; }
if grep -rIniE -f "$PRIVATE" "$DEST" --exclude-dir=.git; then
  echo "✗ Personal data found above: not exported cleanly. Fix the source and run again."
  exit 1
fi
echo "✓ Exported to $DEST ($(find "$DEST" -type f ! -path '*/.git/*' | wc -l | tr -d ' ') files), no personal data found."
