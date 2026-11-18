# Credits and third-party software

- **[KDE Connect](https://kdeconnect.kde.org)** by the KDE community: Janus speaks the KDE Connect protocol, so it
  pairs and works with KDE Connect-based apps. Janus's implementation of the protocol is its own (Swift, in
  `ui/Sources/JanusLink` and `ui/Sources/NativeEngine`); earlier versions bundled KDE Connect's macOS engine
  (GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL; source at
  [invent.kde.org/network/kdeconnect-kde](https://invent.kde.org/network/kdeconnect-kde)).
- **[scrcpy](https://github.com/Genymobile/scrcpy)** by Genymobile and Romain Vimont: the server that runs on the
  phone during mirroring (`assets/scrcpy/scrcpy-server-v4.1`). Apache-2.0, see [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt).
- **[DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit)** by Kai Azim, as used in
  [boring.notch](https://github.com/TheBoredTeam/boring.notch): the notch outline's approach (quadratic curves at the
  corners, animatable radii) in `ui/Sources/Android/Notch/NotchShape.swift`. MIT. The notch window's design also
  draws on boring.notch and [vorssaint-utils](https://github.com/vorssaint/vorssaint-utils) (both GPL-3.0); no code
  was copied from them.
- **Android SDK Platform-Tools (adb)**: used for mirroring, installed separately (not included with Janus).
