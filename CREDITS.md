# Credits and third-party software

- **[KDE Connect](https://kdeconnect.kde.org)** by the KDE community: Janus speaks the KDE Connect protocol, so it
  pairs and works with KDE Connect-based apps. Janus's implementation of the protocol is its own (Swift, in
  `ui/Sources/JanusLink` and `ui/Sources/NativeEngine`); earlier versions bundled KDE Connect's macOS engine
  (GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL; source at
  [invent.kde.org/network/kdeconnect-kde](https://invent.kde.org/network/kdeconnect-kde)).
- **[scrcpy](https://github.com/Genymobile/scrcpy)** by Genymobile and Romain Vimont: the server that runs on the
  phone during mirroring (`assets/scrcpy/scrcpy-server-v4.1`). Apache-2.0, see [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt).
- **Android SDK Platform-Tools (adb)**: used for mirroring, installed separately (not included with Janus).
