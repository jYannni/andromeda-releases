# Andromeda

Andromeda is a free macOS app that shows what uses space on your Mac, explains System Data, and lets you review what to clean up or organize. It requires an Apple silicon Mac running macOS 26 or later.

[Download Andromeda](https://github.com/jYannni/andromeda-releases/releases/latest) · [Sparkle update feed](https://jyannni.github.io/andromeda-releases/updates/appcast.xml)

Open the DMG and drag Andromeda to Applications. If you used the DiskPlain private beta, quit DiskPlain and replace it with this release to switch to the public update feed.

## Build from source

Install Xcode with the macOS 26 SDK or later, then run `swift build -c release` from this folder. `VERSION` identifies this source snapshot. `scripts/build-app.sh` shows how the official release bundles and signs the app, icon and helper programs.

Andromeda is distributed under the [GNU General Public License v3](LICENSE).
