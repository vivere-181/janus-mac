#!/bin/zsh
# Builds the native interface into build.noindex/Janus.app (".noindex" keeps it out of Spotlight).
# apply.sh embeds KDE Connect's engine into a copy of this bundle and installs it in /Applications.
set -e
M=${0:A:h:h}
# The app's identity. Forks: set JANUS_BUNDLE_ID to your own reverse-DNS id (e.g. io.github.<you>.janus).
BUNDLE_ID=${JANUS_BUNDLE_ID:-io.github.vivere-181.janus}
cd "$M/ui"
XC_DEV=$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)
[[ -n "$XC_DEV" ]] && export DEVELOPER_DIR="$XC_DEV/Contents/Developer"   # SwiftUI's macros need full Xcode
swift build -c release --product Android > "$M/build.noindex/build.log" 2>&1 || { grep -E "error:" "$M/build.noindex/build.log" | sort -u; echo "build failed"; exit 1; }
BIN=$(swift build -c release --product Android --show-bin-path)/Android
[[ -x "$BIN" ]] || { echo "build failed"; exit 1; }

APP="$M/build.noindex/Janus.app"
rm -rf "$APP" "$M/build.noindex/Android.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Janus"
# App icon (Janus, shared/icon): light, dark and tinted appearances from assets/Janus.icon via Xcode's actool;
# without Xcode, a light-only icon from the 1024 px render.
XC=$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)
IC="$M/build.noindex/icon"; rm -rf "$IC"; mkdir -p "$IC"
# The same catalog carries the app's accent colour (Janus navy, R32), used by macOS's own controls.
if [[ -n "$XC" ]] && DEVELOPER_DIR="$XC/Contents/Developer" xcrun actool "$M/assets/Janus.icon" "$M/assets/Colors.xcassets" \
     --compile "$IC" --platform macosx --minimum-deployment-target 26.0 --app-icon Janus --accent-color AccentColor \
     --output-partial-info-plist "$IC/partial.plist" >/dev/null 2>&1; then
  cp "$IC/Assets.car" "$IC/Janus.icns" "$APP/Contents/Resources/"
  # The dark design as its own icon, for the app's "App icon" setting (Dock icon while running).
  DC="$IC/dark"; mkdir -p "$DC"
  DEVELOPER_DIR="$XC/Contents/Developer" xcrun actool "$M/assets/JanusDark.icon" --compile "$DC" --platform macosx \
    --minimum-deployment-target 26.0 --app-icon JanusDark --output-partial-info-plist "$DC/partial.plist" >/dev/null 2>&1 \
    && cp "$DC/JanusDark.icns" "$APP/Contents/Resources/"
else
  I="$IC/Janus.iconset"; mkdir -p "$I"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$M/shared/icon/janus-light.png" --out "$I/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$M/shared/icon/janus-light.png" --out "$I/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns -o "$APP/Contents/Resources/Janus.icns" "$I"
fi
cp "$M/assets/menubar-janus.svg" "$APP/Contents/Resources/MenuBarIcon.svg"
# Phone mirroring: the scrcpy server (v4.1, Apache-2.0, SHA-256 deacb991…0cae), pushed to the phone per session.
cp "$M/assets/scrcpy/scrcpy-server-v4.1" "$APP/Contents/Resources/scrcpy-server"
# adb (Android platform tools, universal), so mirroring works on Macs without the Android SDK. Taken from this Mac's
# platform tools when present; without it the app looks for adb on the Mac at runtime.
ADB_SRC=$(for c in "${ANDROID_HOME:-}/platform-tools/adb" "/opt/homebrew/bin/adb" "/usr/local/bin/adb" "$HOME/Library/Android/sdk/platform-tools/adb"; do [[ -x "$c" ]] && { echo "$c"; break; }; done)
if [[ -n "$ADB_SRC" ]]; then
  mkdir -p "$APP/Contents/Helpers"
  cp "$(readlink -f "$ADB_SRC")" "$APP/Contents/Helpers/adb"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Janus</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Janus</string>
  <key>CFBundleDisplayName</key><string>Janus</string>
  <key>CFBundleIconFile</key><string>Janus</string>
  <key>CFBundleIconName</key><string>Janus</string>
  <key>NSAccentColorName</key><string>AccentColor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Janus can connect to your phone over Bluetooth when Wi-Fi is not available.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Janus finds and connects to your phone on your local Wi-Fi network.</string>
  <key>NSBonjourServices</key>
  <array><string>_adb-tls-pairing._tcp</string><string>_adb-tls-connect._tcp</string></array>
  <key>CFBundleURLTypes</key>
  <array>
    <dict><key>CFBundleURLName</key><string>Janus actions</string>
      <key>CFBundleURLSchemes</key><array><string>janus</string><string>androidconnect</string></array></dict>
    <dict><key>CFBundleURLName</key><string>Phone numbers</string>
      <key>CFBundleURLSchemes</key><array><string>tel</string><string>telprompt</string><string>callto</string></array></dict>
  </array>
  <key>NSServices</key>
  <array><dict>
    <key>NSMenuItem</key><dict><key>default</key><string>Send to Phone with Janus</string></dict>
    <key>NSMessage</key><string>sendToPhone</string>
    <key>NSPortName</key><string>Janus</string>
    <key>NSRequiredContext</key><dict/>
    <key>NSSendTypes</key><array><string>NSFilenamesPboardType</string><string>public.plain-text</string></array>
  </dict></array>
</dict></plist>
PLIST
# Shortcuts actions: generate the App Intents metadata macOS reads from the bundle.
# (SwiftPM builds emit the compiler's constant values but don't run Xcode's metadata step.)
IB="$M/build.noindex/intents"; rm -rf "$IB"; mkdir -p "$IB"
find "$M/ui/.build" -path '*Release*' -path '*Android-p.build*' -name '*.swiftconstvalues' > "$IB/constvals.list"
find "$M/ui/Sources/Android" -name '*.swift' > "$IB/sources.list"
xcrun appintentsmetadataprocessor --output "$APP/Contents/Resources" \
  --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")" \
  --module-name Android --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
  --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
  --platform-family macOS --deployment-target 26.0 --target-triple arm64-apple-macos26.0 \
  --source-file-list "$IB/sources.list" --swift-const-vals-list "$IB/constvals.list" > "$IB/log.txt" 2>&1 \
  || { tail -5 "$IB/log.txt"; echo "App Intents metadata failed"; exit 1; }
# Share menu extension ("Janus" in every app's Share menu). Built with swiftc directly: SwiftPM
# can't produce .appex bundles. Extensions must be sandboxed; see ShareExtension/*.entitlements.
EX="$APP/Contents/PlugIns/AndroidShare.appex"
mkdir -p "$EX/Contents/MacOS" "$EX/Contents/Resources"
xcrun swiftc -O -parse-as-library -module-name AndroidShare -target arm64-apple-macos26.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" "$M/ui/ShareExtension/ShareViewController.swift" \
  -o "$EX/Contents/MacOS/AndroidShare" -Xlinker -e -Xlinker _NSExtensionMain > "$M/build.noindex/share.log" 2>&1 \
  || { grep -E "error" "$M/build.noindex/share.log"; echo "share extension failed"; exit 1; }
cp "$APP/Contents/Resources/Janus.icns" "$EX/Contents/Resources/AppIcon.icns"
cat > "$EX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.share</string>
  <key>CFBundleName</key><string>Janus</string>
  <key>CFBundleDisplayName</key><string>Janus</string>
  <key>CFBundleExecutable</key><string>AndroidShare</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSExtension</key><dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.share-services</string>
    <key>NSExtensionPrincipalClass</key><string>AndroidShare.ShareViewController</string>
    <key>NSExtensionAttributes</key><dict>
      <key>NSExtensionActivationRule</key><dict>
        <key>NSExtensionActivationSupportsFileWithMaxCount</key><integer>100</integer>
        <key>NSExtensionActivationSupportsImageWithMaxCount</key><integer>100</integer>
        <key>NSExtensionActivationSupportsMovieWithMaxCount</key><integer>100</integer>
        <key>NSExtensionActivationSupportsAttachmentsWithMaxCount</key><integer>100</integer>
        <key>NSExtensionActivationSupportsWebURLWithMaxCount</key><integer>1</integer>
        <key>NSExtensionActivationSupportsText</key><true/>
      </dict>
    </dict>
  </dict>
</dict></plist>
PLIST
codesign --force --sign - --entitlements "$M/ui/ShareExtension/AndroidShare.entitlements" "$EX" 2>/dev/null
codesign --force --sign - "$APP" 2>/dev/null
echo "built $APP"
