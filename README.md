# MPRIS MiniPlayer

[![Github Latest Releases](https://img.shields.io/github/downloads/ChrisLauinger77/mpris-miniplayer/latest/total)]()
[![Version](https://img.shields.io/github/v/release/ChrisLauinger77/mpris-miniplayer)]()
[![Github All Releases](https://img.shields.io/github/downloads/ChrisLauinger77/mpris-miniplayer/total.svg)]()
[![license](https://img.shields.io/github/license/ChrisLauinger77/mpris-miniplayer)]()

MPRIS MiniPlayer is a small GTK4/libadwaita mini player for Linux media players that expose the MPRIS interface on the session D-Bus.

It is not tied to a specific player. It is intended to work with Sidra, VLC, Spotify, Strawberry, Rhythmbox, Elisa, browsers exposing media sessions, Mopidy, spotifyd, mpv with an MPRIS plugin, and similar clients.

## Screenshot

![MPRIS MiniPlayer showing a Sidra track](data/screenshots/miniplayer.png)

## Install

Download the latest release asset from the [GitHub releases page](https://github.com/ChrisLauinger77/mpris-miniplayer/releases/latest).

For Flatpak, install the bundle with:

```bash
flatpak install --user ./MPRIS-MiniPlayer-<version>-x86_64.flatpak
```

For Debian or Ubuntu on amd64, install the Debian package with:

```bash
sudo apt install ./mpris-miniplayer_<version>_amd64.deb
```

Run it from your application launcher, or from a terminal.

For Flatpak:

```bash
flatpak run io.github.ChrisLauinger.MprisMiniPlayer
```

For the Debian package:

```bash
mpris-miniplayer
```

MPRIS MiniPlayer needs at least one running MPRIS-compatible media player to show playback controls.
When it starts without a player, it can stay hidden in the background and show the window automatically later.

## Features

- Detects MPRIS players on the session bus
- Selects the first available player automatically
- Shows track title, artist, album, and album art
- Provides previous, play/pause, and next controls
- Shows playback progress and time
- Lets you seek when the selected player supports it
- Lets you adjust volume when the selected player exposes MPRIS volume control
- Lets you choose between available players
- Provides a compact mode for a smaller window layout
- Updates the UI when player metadata changes
- Can keep running in the background when no player is available
- Can show and hide the window automatically as players appear or disappear
- Provides preferences for compact mode, background notifications, automatic visibility, and start on login
- Hides the window on close; use Quit to stop the app

## Build from Source

Install the typical development dependencies on Debian or Ubuntu:

```bash
sudo apt install meson ninja-build valac libgtk-4-dev libadwaita-1-dev gettext desktop-file-utils appstream
```

Build and run:

```bash
meson setup build
meson compile -C build
./build/src/mpris-miniplayer
```

Install locally:

```bash
sudo meson install -C build
```

Uninstall the local build:

```bash
sudo ninja -C build uninstall
```

## Maintainer Release

Pushing a version tag builds a Flatpak bundle, builds an amd64 Debian package, and creates a GitHub release:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The release workflow attaches `MPRIS-MiniPlayer-<tag>-x86_64.flatpak` and `mpris-miniplayer_<tag>_amd64.deb` to the generated release.

## License

MPRIS MiniPlayer is licensed under the GNU General Public License v3.0 or later.

## Roadmap

v0.1:

- Detect active MPRIS players on the session bus
- Select first usable player automatically
- Display track title, artist, album, and album art when available
- Provide previous, play/pause, and next controls
- Update UI when metadata changes
- Provide a small libadwaita window
- Provide a basic Meson build and working desktop file
- Add CI build workflow

v0.2:

- Run in the background when no MPRIS player is available
- Show and hide the window automatically when players appear or disappear
- Show an optional background notification with an Open action
- Add preferences for notifications, automatic visibility, and start on login
- Hide the window on close and quit only through an explicit Quit action

v0.3:

- Add player volume control
- Add compact mode

v1.0:

- Polish AppStream metadata for clean validation
- Add icon package integration
- Add Debian packaging and amd64 release packages
