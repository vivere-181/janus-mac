# Janus for Mac

Your Android phone and your Mac, working together. Notifications, calls and messages, files and links, the
clipboard, your phone's calendar, shared notes, live activities and phone mirroring, all in a native macOS app that
lives in the menu bar.

Janus for Mac works with **[Janus for Android](https://github.com/vivere-181/janus-android)** on your phone. Janus is
named after the Roman god of doorways, who looks both ways: one app, two sides.

**[Download Janus for Mac](https://github.com/vivere-181/janus-mac/releases/latest)** · macOS 26 or later, Apple silicon

## Features

- **Notifications**: your phone's notifications as cards on the Mac, with replies and actions, kept for 24 hours.
- **Calls and messages**: incoming calls, calling from the Mac, SMS conversations, and verification codes copied
  for you.
- **Files, links and the clipboard**: drag files to the phone, open links where you want them, copy on one device
  and paste on the other. Janus is in the Mac's Share menu, too.
- **Calendar**: your phone's calendars, a week view, reminders, and a countdown to the next meeting in the menu bar.
- **Notes**: notes with formatting, checklists, tables and attachments, synced with the phone, with a Quick Note
  shortcut and desktop widgets where you can tick off checklist items.
- **Live activities**: deliveries, rides, timers and navigation from the phone, in the menu bar.
- **Mirroring**: see and control your phone's screen, with sound, even while the phone's screen stays off.
- **Your Mac from your phone**: lock, mute, find your Mac, take screenshots, or use the phone as a touchpad and
  keyboard.
- **Android TV**: a TV remote in the menu bar (keys, typing, voice search, the TV's apps), and AirPlay screen
  mirroring to Janus on the TV.

## Install

1. Download `Janus-<version>.dmg` from the [latest release](https://github.com/vivere-181/janus-mac/releases/latest),
   open it, and drag **Janus** to **Applications**.
2. Open Janus. The first time, macOS says it can't check Janus for malware, because Janus isn't notarized by Apple.
   Click **Done**, open **System Settings → Privacy & Security**, scroll to "Janus was blocked…" and click
   **Open Anyway**. You only do this once: updates install from inside the app.
3. Janus walks you through the rest:
   - **Get the app**: scan the first code with your phone's camera to download Janus for Android. Your phone asks to
     allow installing apps from your browser; that's expected, because Janus isn't in the Play Store.
   - **Pair**: open Janus on the phone and scan the second code. There's no code to compare: the QR code itself
     proves it's your Mac.
   - **Permissions**: turn on notifications, opening at login, and, if you'd like to control the Mac from your
     phone, Accessibility. You can change these anytime.

Your phone and your Mac need to be on the same Wi-Fi network.

### Updates

Janus checks for updates once a day and tells you when one is ready. Choose **Janus → Check for Updates…** to check
now, or turn automatic checks off in **Settings → General → Software Update**. An update installs only if it's
signed by the same certificate as your copy of Janus, and it keeps your settings, pairings and permissions.

### Mirroring

Mirroring needs Android 11 or later with Wireless debugging (Janus walks you through turning it on), and Android's
`adb` tool on the Mac:

```sh
brew install --cask android-platform-tools
```

## Privacy

- Janus has no account and no Janus server, and it collects no analytics. Your phone and your Mac talk to each other
  directly on your network.
- Everything between them is encrypted (TLS), and only devices you've paired can connect.
- Janus goes online only to check GitHub for updates, and to reach your own relay if you set up Janus Cloud.
- **Janus Cloud** (optional) keeps your devices connected when they aren't on the same network, through a relay you
  run yourself. Everything is encrypted on your devices, so the relay can't read your files or their names.

## Troubleshooting

- **Janus doesn't find your phone**: check that both are on the same Wi-Fi, and that Janus is allowed in
  **System Settings → Privacy & Security → Local Network**. Guest and public networks often keep devices from seeing
  each other.
- **A firewall is on**: allow incoming connections for Janus. It uses UDP port 1716 and TCP ports 1716–1764.
- **Permissions reset after every build from source**: ad-hoc signed builds look like a new app to macOS each
  time. See *Signing* below.

## Uninstall

Click Janus in the menu bar and choose **Quit Janus**, then move **Janus** from Applications to the Trash. To also
remove your pairings and data, delete `~/Library/Application Support/Android`.

## Building from source

1. **Tools**: Xcode 26 or later. You need the full Xcode: the command-line tools alone lack SwiftUI's macros and the
   icon compiler. Everything else Janus needs is in this repository.
2. **Build and install**:

   ```sh
   tools/build-ui.sh   # builds build.noindex/Janus.app
   ./apply.sh          # installs /Applications/Janus.app, signs it and opens it
   ```

   Run `./apply.sh` again after every change. `tools/package.sh` makes the release files
   (`build.noindex/dist/Janus-<version>.dmg` and `.zip`), and `tools/release.sh notes.md` publishes them.
3. **Signing** (optional): with an ad-hoc signature, macOS asks for permissions again after every build, and in-app
   updates won't install over it. To keep permissions, create a self-signed certificate named
   "Janus Local Signing": in Keychain Access, choose **Certificate Assistant → Create a Certificate…**, then
   **Self Signed Root** and **Code Signing**.
4. **Tests**: `swift test --filter JanusLinkTests` (in `ui/`, with Xcode selected) checks the protocol pieces.

## How it works

The two apps speak the open **[KDE Connect](https://kdeconnect.kde.org)** protocol (version 8), plus a few messages
of their own, documented in [docs/PROTOCOL.md](docs/PROTOCOL.md). Janus for Mac has its own implementation of the
protocol in Swift, built into the app, so there's nothing else to install.

| Path | What |
|---|---|
| `ui/Sources/Android/` | The Mac app (SwiftUI and AppKit). The folder keeps the project's original module name. |
| `ui/Sources/JanusLink/` | The KDE Connect protocol in Swift: discovery, TLS, pairing, packets and file transfers. |
| `ui/Sources/NativeEngine/` | The engine: devices and their features (notifications, files, clipboard, media…). |
| `ui/Sources/KDEConnectKit/` | The engine's object model as the app sees it, and your phone's contacts. |
| `ui/Sources/JanusWidgets/`, `WidgetFeed/` | The notes widgets, and the data the app shares with them. |
| `ui/ShareExtension/`, `ui/WidgetExtension/` | Janus in the Share menu, and the widget extension. |
| `ui/Sources/linkprobe/` | A command-line tool for testing the protocol against a device. |
| `ui/Tests/` | Tests for the protocol pieces (pairing codes match Janus for Android's). |
| `tools/` | Build, signing, packaging and release scripts. |
| `assets/` | The app icon (Icon Composer), accent colour, menu bar icon, and the scrcpy server used for mirroring. |

## Licence

Janus for Mac is free software under the **GNU General Public License v3.0** (see [LICENSE](LICENSE)). It includes
or works with third-party software under their own licences; see [CREDITS.md](CREDITS.md).

Janus is not affiliated with KDE, Google or Apple. "KDE" and "KDE Connect" are trademarks of KDE e.V. Android is a
trademark of Google LLC; Mac and macOS are trademarks of Apple Inc.
