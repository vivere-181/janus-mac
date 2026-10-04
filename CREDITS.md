# Credits and third-party software

- **[KDE Connect](https://invent.kde.org/network/kdeconnect-kde)**: the connection engine (pairing, encryption,
  transport and the KDE Connect protocol). GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL. Janus uses
  the KDE Connect macOS build, renamed and without KDE's own interface; its source is available from KDE at the link
  above. It ships with Qt (LGPL-3.0), KDE Frameworks (mostly LGPL-2.1-or-later) and D-Bus (AFL-2.1 / GPL-2.0).
- **[scrcpy](https://github.com/Genymobile/scrcpy)** by Genymobile and Romain Vimont: the server that runs on the
  phone during mirroring (`assets/scrcpy/scrcpy-server-v4.1`). Apache-2.0, see [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt).
- **Android SDK Platform-Tools (adb)**: used for mirroring. Release builds may include adb from Google's
  platform-tools; adb is built from the Android Open Source Project (Apache-2.0), and Google's prebuilt binaries are
  distributed under the Android SDK terms.
