#!/bin/zsh
# Signs a built Janus.app inside-out (extensions with their entitlements, then the app) and checks it.
# A stable certificate keeps macOS permissions (Screen Recording, Accessibility…) across updates and is what in-app
# updates check; ad-hoc signatures change with every build. Uses "Janus Local Signing" (Keychain Access →
# Certificate Assistant → Create a Certificate…, Self Signed Root, Code Signing) or an Apple Development certificate.
#   tools/sign.sh <path/to/Janus.app>
set -e
M=${0:A:h:h}
APP=${1:?usage: tools/sign.sh <Janus.app>}
ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
SIGN=-
if security find-identity -p codesigning 2>/dev/null | grep -q '"Janus Local Signing"'; then
  SIGN="Janus Local Signing"
else
  DEV=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Apple Development' | awk '{print $2}')
  [ -n "$DEV" ] && SIGN="$DEV"
fi
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
rm -f "$APP/Icon"$'\r'
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
for ext in "$APP"/Contents/PlugIns/*.appex(N); do
  ent="$M/ui/ShareExtension/AndroidShare.entitlements"
  [[ ${ext:t} == JanusWidgets.appex ]] && ent="$M/ui/WidgetExtension/JanusWidgets.entitlements"
  codesign --force --sign "$SIGN" --entitlements "$ent" "$ext" 2>&1 | grep -v 'replacing existing signature' || true
done
codesign --force --sign "$SIGN" --identifier "$ID" "$APP" 2>&1 | grep -v 'replacing existing signature' || true
codesign --verify --deep --strict "$APP"
if [ "$SIGN" = "-" ]; then
  echo "• Signature OK (ad-hoc: permissions must be re-allowed after each update)"
else
  echo "• Signature OK (stable certificate: permissions are kept)"
fi
