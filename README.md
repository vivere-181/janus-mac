# Janus for Mac

Janus connects your Android phone and your Mac: notifications, calls and messages, files and links, the clipboard,
your phone's calendar, shared notes, live activities like deliveries and timers, and phone mirroring, all from a
native macOS app that lives in the menu bar.

It works together with **[Janus for Android](https://github.com/vivere-181/janus-android)** on the phone. The two talk
using the open **[KDE Connect](https://kdeconnect.kde.org)** protocol; Janus has its own implementation of it in
Swift, built into the app.

## Features

- **Notifications**: the phone's notifications as cards on the Mac, with replies and actions; kept for 24 hours.
- **Calls and messages**: incoming calls, calling from the Mac, SMS conversations, verification codes copied for you.
- **Files, links, clipboard**: drag files to the phone, links open where you want them, a shared clipboard.
- **Calendar**: the phone's calendars, a week view, reminders and a countdown in the menu bar.
- **Notes**: notes with formatting, checklists, tables and attachments, synced with the phone, plus a Quick Note
  shortcut.
- **Live activities**: deliveries, rides, timers and navigation from the phone in the menu bar.
- **Mirroring**: see and control the phone's screen (with sound), even while the phone's screen stays off.
- **Mac controls from the phone**: lock, mute, find your Mac, screenshots; the phone as the Mac's touchpad.
- **TV**: a remote for Android TV in the menu bar (keys, typing, voice, its apps), and AirPlay mirroring to Janus on
  the TV.

## Install

1. Download **Janus-<version>.dmg** from the [latest release](https://github.com/vivere-181/janus-mac/releases/latest),
   open it and drag **Janus** into **Applications**.
2. The first time you open it, macOS says it can't check Janus for malware (Janus isn't notarized by Apple). Click
   **Done**, then open **System Settings → Privacy & Security**, scroll down to "Janus was blocked…" and click
   **Open Anyway**. This is needed once; updates install from inside the app afterwards.
3. Janus welcomes you: scan the first code with your phone's camera to get **Janus for Android**, then scan the
   second one in Janus on the phone to pair. That's it.

Janus checks for updates once a day (Settings → Software Update) and installs them itself, keeping your settings,
pairings and permissions.

## Requirements

- macOS 26 or later (Apple silicon).
- An Android phone with Janus for Android, on the same Wi-Fi network as the Mac. (Janus Cloud, optional, keeps them
  connected through your own relay when they aren't.)
- For mirroring: Android 11 or later with Wireless debugging (the app walks you through it), and `adb` on the Mac:
  `brew install --cask android-platform-tools`.

## Building from source

1. **Tools**: Xcode 26 or later (full Xcode: the command-line tools alone lack SwiftUI's macros and the icon compiler).
   No other downloads: everything Janus needs is in this repository.
2. **Build and install**:

   ```sh
   tools/build-ui.sh   # builds build.noindex/Janus.app
   ./apply.sh          # installs /Applications/Janus.app, signs it and opens it
   ```

   Run `./apply.sh` again after every change. `tools/package.sh` makes the release files
   (`build.noindex/dist/Janus-<version>.dmg` and `.zip`); `tools/release.sh notes.md` publishes them.
3. **Signing** (optional): with an ad-hoc signature, macOS asks for permissions again after each build, and in-app
   updates won't install over it. A self-signed certificate named "Janus Local Signing" (Keychain Access →
   Certificate Assistant → Create a Certificate…, Self Signed Root, Code Signing) keeps them.
4. **Tests**: `swift test --filter JanusLinkTests` (in `ui/`, with Xcode selected) checks the protocol pieces.

## Repository layout

| Path | What |
|---|---|
| `ui/Sources/Android/` | The Mac app (SwiftUI and AppKit). The folder keeps the project's original module name. |
| `ui/Sources/JanusLink/` | The KDE Connect protocol in Swift: discovery, TLS, pairing, packets, file transfers. |
| `ui/Sources/NativeEngine/` | The engine: devices and their features (notifications, files, clipboard, media…). |
| `ui/Sources/KDEConnectKit/` | The engine's object model as the app sees it, and the phone's contacts. |
| `ui/ShareExtension/` | "Janus" in the macOS Share menu. |
| `tools/` | Build, packaging and developer scripts. |
| `assets/` | App icon (Icon Composer), accent colour, menu bar icon, the scrcpy server used for mirroring. |
| `docs/PROTOCOL.md` | The companion protocol between the two apps, on top of KDE Connect. |
| `ui/Tests/` | Tests for the protocol pieces (pairing codes match Janus for Android's). |

## Licence

Janus for Mac is free software under the **GNU General Public License v3.0** (see [LICENSE](LICENSE)). It includes
or works with third-party software under their own licences; see [CREDITS.md](CREDITS.md).

Janus is not affiliated with KDE, Google or Apple. Android is a trademark of Google LLC; Mac and macOS are
trademarks of Apple Inc.
