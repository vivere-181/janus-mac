#!/bin/zsh
# Installs / re-applies Janus.app. Run after every KDE Connect update:
#   ./apply.sh   (from the repository folder)
#
# Layout it produces:
#   Janus.app                                   native macOS interface (bundle id set in tools/build-ui.sh)
#     Contents/Library/Engine/Janus Engine.app  the connection engine (KDE Connect technology),
#                                               renamed, stripped of KDE's own UI/tools/branding
#
# Accepts a freshly downloaded "KDE Connect.app" in /Applications, the older layout where
# the app *was* KDE Connect, or an already-converted app under its earlier name (Android.app) or this one.
# (TARGET/FRESH env vars exist only for testing on a copy.)
set -e
M=${0:A:h}
APP=${TARGET:-/Applications/Janus.app}
OLD_APP=/Applications/Android.app   # the app's name before 2026-10-04
FRESH=${FRESH:-"/Applications/KDE Connect.app"}
SHELL_APP="$M/build.noindex/Janus.app"
ENGINE_DIR="$APP/Contents/Library/Engine"
ENGINE="$ENGINE_DIR/Janus Engine.app"
OLD_ENGINE="$ENGINE_DIR/Android Engine.app"
LEGACY_ENGINE="$ENGINE_DIR/KDE Connect.app"
STAGE="$M/build.noindex/stage"
PB=/usr/libexec/PlistBuddy
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[[ -x "$SHELL_APP/Contents/MacOS/Janus" ]] || "$M/tools/build-ui.sh"
ID=$($PB -c "Print :CFBundleIdentifier" "$SHELL_APP/Contents/Info.plist")   # the app's bundle id (from the build)

# 0. Stop the interface, the engine (old and new names) and its message buses.
if [[ -z "$TARGET" ]]; then
  pkill -f "/Applications/Janus.app/Contents/" 2>/dev/null || true
  pkill -f "/Applications/Android.app/Contents/" 2>/dev/null || true
  pkill -f "/Applications/KDE Connect.app/Contents/" 2>/dev/null || true
  pkill -x kdeconnectd 2>/dev/null || true
  pkill -x "Janus Engine" 2>/dev/null || true
  pkill -x "Android Engine" 2>/dev/null || true
  rm -f /tmp/private_dbus_address "${TMPDIR:-/tmp/}android-connect-bus-address"
  sleep 1
fi

# 0b. The app was called Android.app: it becomes Janus.app (same identity, so permissions and data stay).
if [[ -z "$TARGET" && -d "$OLD_APP" && ! -d "$APP" ]]; then
  $LSR -u "$OLD_APP" 2>/dev/null || true
  mv "$OLD_APP" "$APP"
  echo "• Renamed Android.app to Janus.app"
fi
[[ -d "$OLD_ENGINE" && ! -d "$ENGINE" ]] && mv "$OLD_ENGINE" "$ENGINE"

# 1. Put the right engine bundle in place.
rm -rf "$STAGE"; mkdir -p "$STAGE"
NEW_ENGINE=""
if [[ -d "$FRESH" ]]; then
  mv "$FRESH" "$STAGE/engine.app"; NEW_ENGINE="update"
elif [[ -x "$APP/Contents/MacOS/kdeconnectd" ]]; then
  mv "$APP" "$STAGE/engine.app"; NEW_ENGINE="converted oldest layout"
fi
if [[ ! -d "$APP" ]]; then
  ditto "$SHELL_APP" "$APP"
fi
if [[ -d "$LEGACY_ENGINE" && ! -d "$ENGINE" && -z "$NEW_ENGINE" ]]; then
  mv "$LEGACY_ENGINE" "$ENGINE"; echo "• Engine: renamed"
fi
if [[ -n "$NEW_ENGINE" ]]; then
  for old in "$ENGINE" "$LEGACY_ENGINE"; do
    [[ -d "$old" ]] && mv "$old" ~/.Trash/"Janus engine (replaced $(date '+%Y-%m-%d %H.%M.%S')).app"
  done
  mkdir -p "$ENGINE_DIR"
  mv "$STAGE/engine.app" "$ENGINE"
  echo "• Engine: $NEW_ENGINE"
fi
rm -rf "$STAGE"
[[ -d "$ENGINE" ]] || { echo "No engine found (expected $FRESH or an existing Janus.app / Android.app)"; exit 1; }

# 2. Interface: refresh binary, Info.plist and resources from the latest build.
rm -rf "$APP/Contents/Resources/kdeconnect-icons"
rm -rf "$APP/Contents/MacOS"   # (the interface's executable was "Android" before the rename)
ditto "$SHELL_APP/Contents/MacOS" "$APP/Contents/MacOS"
rm -f "$APP/Contents/Resources/AppIcon.icns"   # the icon before Janus
ditto "$SHELL_APP/Contents/Resources" "$APP/Contents/Resources"
rm -rf "$APP/Contents/PlugIns"
[[ -d "$SHELL_APP/Contents/PlugIns" ]] && ditto "$SHELL_APP/Contents/PlugIns" "$APP/Contents/PlugIns"
# adb for mirroring (bundled so other Macs don't need the Android SDK).
[[ -d "$SHELL_APP/Contents/Helpers" ]] && ditto "$SHELL_APP/Contents/Helpers" "$APP/Contents/Helpers"
cp "$SHELL_APP/Contents/Info.plist" "$APP/Contents/Info.plist"
echo "• Interface installed"

# 3. Engine: own name and identity, no KDE UI/tools, no pop-ups of its own (the interface
#    posts all notifications), fixed icon. KDE's libraries and plugins stay untouched.
EC="$ENGINE/Contents"; EP="$EC/Info.plist"; ER="$EC/Resources"; EM="$EC/MacOS"
for old in kdeconnectd "Android Engine"; do [[ -f "$EM/$old" ]] && mv -f "$EM/$old" "$EM/Janus Engine"; done
for old in dbus-daemon "Android Bus"; do [[ -f "$EM/$old" ]] && mv -f "$EM/$old" "$EM/Janus Bus"; done
for f in "KDE Connect" Android kdeconnect-app kdeconnect-cli kdeconnect-handler kdeconnect-sms \
         cmake_automoc_parser dbus-daemon-launch-helper moc qlalr qmlaotstats qmlcachegen qmlimportscanner \
         qmljsrootgen qmltyperegistrar qvkgen rcc syncqt tracegen tracepointgen uic; do
  rm -rf "$EM/$f"
done
for d in Thunar nautilus-python deepin contractor applications metainfo zsh kdevappwizard; do rm -rf "$ER/$d"; done
rm -f "$ER"/sc-apps-kdeconnect.icns "$ER"/1sc-apps-kdeconnect.icns
cp "$SHELL_APP/Contents/Resources/Janus.icns" "$ER/AppIcon.icns"
$PB -c "Set :CFBundleExecutable Janus Engine" "$EP"
$PB -c "Set :CFBundleIdentifier $ID.engine" "$EP"
$PB -c "Set :CFBundleName Janus" "$EP"
$PB -c "Set :CFBundleIconFile AppIcon" "$EP"
$PB -c "Delete :CFBundleDisplayName" "$EP" 2>/dev/null || true
$PB -c "Add :CFBundleDisplayName string Janus" "$EP"
$PB -c "Delete :NSServices" "$EP" 2>/dev/null || true
NRC="$ER/knotifications6/kdeconnect.notifyrc"
if [[ -f "$NRC" ]]; then
  # Global name "Janus" (drop translated "KDE Connect" names); every event: no pop-up.
  awk '/^\[Global\]/{g=1} /^\[Event/{g=0}
       g && /^Name\[/ {next}
       g && /^Name=/ {print "Name=Janus"; next}
       /^Action=/ {print "Action="; next}
       {print}' "$NRC" > "$NRC.tmp" && mv "$NRC.tmp" "$NRC"
fi
echo "• Engine configured"

# 4. Clean metadata codesign rejects, then sign inside-out for this Mac.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
rm -f "$APP/Icon"$'\r' "$ENGINE/Icon"$'\r'
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -d com.apple.FinderInfo "$ENGINE" 2>/dev/null || true
# A stable certificate keeps macOS permissions (Screen Recording, Bluetooth…) across updates; ad-hoc
# signatures change with every build, so macOS treats each update as a new app. Uses a certificate
# named "Janus Local Signing" (Keychain Access → Certificate Assistant → Create a Certificate…,
# Identity Type: Self Signed Root, Certificate Type: Code Signing) or an Apple Development one if present.
# ("Android Local Signing" is the name used before the app was called Janus.)
SIGN=-
if security find-identity -p codesigning 2>/dev/null | grep -q '"Janus Local Signing"'; then
  SIGN="Janus Local Signing"
elif security find-identity -p codesigning 2>/dev/null | grep -q '"Android Local Signing"'; then
  SIGN="Android Local Signing"
else
  DEV=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Apple Development' | awk '{print $2}')
  [ -n "$DEV" ] && SIGN="$DEV"
fi
codesign --force --sign "$SIGN" --identifier "$ID.engine.daemon" "$EM/Janus Engine" 2>/dev/null || true
codesign --force --sign "$SIGN" --identifier "$ID.engine.bus" "$EM/Janus Bus" 2>/dev/null || true
codesign --force --sign "$SIGN" --identifier "$ID.engine" "$ENGINE" 2>&1 | grep -v 'replacing existing signature' || true
for ext in "$APP"/Contents/PlugIns/*.appex(N); do
  codesign --force --sign "$SIGN" --entitlements "$M/ui/ShareExtension/AndroidShare.entitlements" "$ext" 2>&1 | grep -v 'replacing existing signature' || true
done
codesign --force --sign "$SIGN" --identifier "$ID" "$APP" 2>&1 | grep -v 'replacing existing signature' || true
codesign --verify --deep --strict "$APP"
if [ "$SIGN" = "-" ]; then
  echo "• Signature OK (ad-hoc: Screen Recording must be re-allowed after each update)"
else
  echo "• Signature OK (stable certificate: permissions are kept)"
fi

# 5. Register with macOS and launch.
touch "$APP"
$LSR -f "$APP" 2>/dev/null || true
if [[ -z "$TARGET" ]]; then
  /System/Library/CoreServices/pbs -update 2>/dev/null || true
  killall Dock NotificationCenter 2>/dev/null || true
  open "$APP"
fi
echo "Done."
