#!/bin/zsh
# Installs Janus.app from the latest build into /Applications, signs it and opens it:
#   ./apply.sh   (from the repository folder)
# Janus has its own connection engine (KDE Connect's protocol, in Swift); nothing else is needed.
# (TARGET exists only for testing on a copy.)
set -e
M=${0:A:h}
APP=${TARGET:-/Applications/Janus.app}
OLD_APP=/Applications/Android.app   # the app's name before 2026-10-04
BUILT="$M/build.noindex/Janus.app"
LSR=/System/Library/CoreServices/Frameworks/LaunchServices.framework/Support/lsregister
[[ -x "$LSR" ]] || LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[[ -x "$BUILT/Contents/MacOS/Janus" ]] || "$M/tools/build-ui.sh"

# 1. Quit Janus, and KDE's engine and message bus from versions before the native engine.
if [[ -z "$TARGET" ]]; then
  pkill -f "/Applications/Janus.app/Contents/" 2>/dev/null || true
  pkill -f "/Applications/Android.app/Contents/" 2>/dev/null || true
  pkill -x "Janus Engine" 2>/dev/null || true
  pkill -x "Janus Bus" 2>/dev/null || true
  rm -f "${TMPDIR:-/tmp/}android-connect-bus-address"
  sleep 1
  # The app was called Android.app: it becomes Janus.app (same identity, so permissions and data stay).
  if [[ -d "$OLD_APP" && ! -d "$APP" ]]; then $LSR -u "$OLD_APP" 2>/dev/null || true; mv "$OLD_APP" "$APP"; fi
fi

# 2. A fresh copy of the build, signed, swapped in (also drops the old bundled engine).
NEW="${APP:h}/.Janus-new.app"
rm -rf "$NEW"
ditto "$BUILT" "$NEW"
echo "• Interface installed"
"$M/tools/sign.sh" "$NEW"
if [[ -d "$APP" ]]; then rm -rf "$APP.previous"; mv "$APP" "$APP.previous"; fi
mv "$NEW" "$APP"
rm -rf "$APP.previous"

# 3. Register with macOS and launch.
touch "$APP"
$LSR -f "$APP" 2>/dev/null || true
if [[ -z "$TARGET" ]]; then
  /System/Library/CoreServices/pbs -update 2>/dev/null || true
  open "$APP"
fi
echo "Done."
