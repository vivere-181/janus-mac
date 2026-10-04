# Janus for Mac

Janus connects your Android phone and your Mac: notifications, calls and messages, files and links, the clipboard,
your phone's calendar, shared notes, live activities like deliveries and timers, and phone mirroring, all from a
native macOS app that lives in the menu bar.

It works together with **[Janus for Android](https://github.com/vivere-181/janus-android)** on the phone. Both are built
on **[KDE Connect](https://kdeconnect.kde.org)**, whose open protocol and engine do the pairing, encryption and
transport.

## Features

- **Notifications**: the phone's notifications as cards on the Mac, with replies and actions; kept for 24 hours.
- **Calls and messages**: incoming calls, calling from the Mac, SMS conversations, verification codes copied for you.
- **Files, links, clipboard**: drag files to the phone, links open where you want them, a shared clipboard.
- **Calendar**: the phone's calendars, a week view, reminders and a countdown in the menu bar.
- **Notes**: notes with formatting, checklists, tables and attachments, synced with the phone, plus a Quick Note
  shortcut.
- **Live activities**: deliveries, rides, timers and navigation from the phone in the menu bar.
- **Mirroring**: see and control the phone's screen (with sound), even while the phone's screen stays off.
- **Mac controls from the phone**: lock, mute, find your Mac, screenshots.

## Requirements

- macOS 26 or later (Apple silicon).
- An Android phone with Janus for Android, on the same Wi-Fi network as the Mac (or paired over Bluetooth).
- For mirroring: Android 11 or later, with Wireless debugging (the app walks you through it).

## Building from source

1. **Tools**: Xcode 26 or later (full Xcode: the command-line tools alone lack SwiftUI's macros and the icon compiler).
2. **The connection engine**: download KDE Connect for macOS from
   [kdeconnect.kde.org/download.html](https://kdeconnect.kde.org/download.html) and put **KDE Connect.app** in
   /Applications. The install script turns it into Janus's engine (renamed and stripped of KDE's own interface).
3. **Build and install**:

   ```sh
   tools/build-ui.sh   # builds build.noindex/Janus.app
   ./apply.sh          # installs /Applications/Janus.app with the engine inside, signs it and opens it
   ```

   Run `./apply.sh` again after every change. For an installer for another Mac, run `tools/package.sh`
   (it writes `build.noindex/dist/Janus-<date>.dmg`).
4. **Signing** (optional): with an ad-hoc signature, macOS asks for some permissions again after each build. A
   self-signed certificate named "Janus Local Signing" (Keychain Access → Certificate Assistant → Create a
   Certificate…, Self Signed Root, Code Signing) keeps them.

On first launch, allow Local Network (to find the phone), Notifications and Bluetooth. Then open Janus on the phone
and pair.

## Repository layout

| Path | What |
|---|---|
| `ui/Sources/Android/` | The Mac app (SwiftUI and AppKit). The folder keeps the project's original module name. |
| `ui/Sources/KDEConnectKit/` | Talks to the KDE Connect engine over D-Bus. |
| `ui/ShareExtension/` | "Janus" in the macOS Share menu. |
| `tools/` | Build, packaging and developer scripts. |
| `assets/` | App icon (Icon Composer), accent colour, menu bar icon, the scrcpy server used for mirroring. |
| `docs/PROTOCOL.md` | The companion protocol between the two apps, on top of KDE Connect. |

Developer tools: Settings → Developer → "Show testing tools" adds a Testing section (simulated notifications, an
inspector for the raw data the phone sends).

## Licence

Janus for Mac is free software under the **GNU General Public License v3.0** (see [LICENSE](LICENSE)). It includes
or works with third-party software under their own licences; see [CREDITS.md](CREDITS.md).

Janus is not affiliated with KDE, Google or Apple. Android is a trademark of Google LLC; Mac and macOS are
trademarks of Apple Inc.
