# MPRIS MiniPlayer

MPRIS MiniPlayer is a small GTK4/libadwaita mini player for Linux media players that expose the MPRIS interface on the session D-Bus.

It is not tied to a specific player. It is intended to work with Sidra, VLC, Spotify, Strawberry, Rhythmbox, Elisa, browsers exposing media sessions, Mopidy, spotifyd, mpv with an MPRIS plugin, and similar clients.

## Screenshot

![MPRIS MiniPlayer showing a Sidra track](data/screenshots/miniplayer.png)

## Features

- Detects MPRIS players on the session bus
- Selects the first available player automatically
- Shows track title, artist, album, and album art
- Provides previous, play/pause, and next controls
- Updates the UI when player metadata changes

## Build

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

- Add a player chooser when multiple MPRIS players are available
- Add a progress bar
- Show current position and duration
- Add seek support if the player supports `CanSeek`
- Poll position periodically while playing
- Disable unsupported buttons according to MPRIS capabilities

v0.3:

- Add compact mode
- Remember window size and position if possible
- Add an always-on-top option if GTK/Wayland support permits it
- Add keyboard shortcuts
- Improve the empty state when no player is running

v1.0:

- Polish AppStream metadata
- Add icons
- Add screenshots
- Add translations
- Add a Flatpak manifest
- Add Debian packaging
- Add CI build workflow
