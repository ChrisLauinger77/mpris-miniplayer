# MPRIS MiniPlayer

MPRIS MiniPlayer is a small GTK4/libadwaita mini player for Linux media players that expose the MPRIS interface on the session D-Bus.

It is not tied to a specific player. It is intended to work with Sidra, VLC, Spotify, Strawberry, Rhythmbox, Elisa, browsers exposing media sessions, Mopidy, spotifyd, mpv with an MPRIS plugin, and similar clients.

## Screenshot

![MPRIS MiniPlayer showing a Sidra track](data/screenshots/miniplayer.png)

## Install

Download the latest Flatpak bundle from the [GitHub releases page](https://github.com/ChrisLauinger77/mpris-miniplayer/releases/latest), then install it with:

```bash
flatpak install --user ./MPRIS-MiniPlayer-<version>-x86_64.flatpak
```

Run it from your application launcher, or from a terminal:

```bash
flatpak run io.github.ChrisLauinger.MprisMiniPlayer
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
- Lets you choose between available players
- Updates the UI when player metadata changes
- Can keep running in the background when no player is available
- Can show and hide the window automatically as players appear or disappear
- Provides preferences for background notifications, automatic visibility, and start on login
- Hides the window on close; use Quit to stop the app

## Build from Source

Install the typical development dependencies on Debian or Ubuntu:

```bash
sudo apt install meson ninja-build valac libgtk-4-dev libadwaita-1-dev gettext desktop-file-utils appstream-util
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

Pushing a version tag builds a Flatpak bundle and creates a GitHub release:

```bash
git tag v0.2.0
git push origin v0.2.0
```

The release workflow attaches `MPRIS-MiniPlayer-<tag>-x86_64.flatpak` to the generated release.

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

v0.2:

- Run in the background when no MPRIS player is available
- Show and hide the window automatically when players appear or disappear
- Show an optional background notification with an Open action
- Add preferences for notifications, automatic visibility, and start on login
- Hide the window on close and quit only through an explicit Quit action

v0.3:

- Add compact mode
- Add keyboard shortcuts

v1.0:

- Polish AppStream metadata
- Add icons
- Add Debian packaging
- Add CI build workflow
