# MPRIS MiniPlayer — Codex Handover

## Project

Build a standalone Linux mini player for MPRIS-compatible media players.

- Visible app name: `MPRIS MiniPlayer`
- Repository / folder: `mpris-miniplayer`
- App ID: `io.github.ChrisLauinger.MprisMiniPlayer`
- Executable: `mpris-miniplayer`
- Desktop file: `io.github.ChrisLauinger.MprisMiniPlayer.desktop`
- AppStream file: `io.github.ChrisLauinger.MprisMiniPlayer.metainfo.xml`

## Goal

Create a small, polished, daily-use mini player for any media player exposing MPRIS on the session D-Bus.

It must not be Sidra-specific.

Target players include Sidra, VLC, mpv with MPRIS plugin, Spotify, Strawberry, Rhythmbox, Elisa, browsers exposing media sessions, Mopidy, spotifyd, and similar clients.

## Chosen stack

Use:

- Vala
- GTK4
- libadwaita
- Gio / GDBus
- Meson

Do not use Python for the long-term implementation.
Do not use raylib/imgui.
Do not make it player-specific.

## Initial repository structure

```text
mpris-miniplayer/
├── data/
│   ├── io.github.ChrisLauinger.MprisMiniPlayer.desktop.in
│   ├── io.github.ChrisLauinger.MprisMiniPlayer.metainfo.xml.in
│   └── icons/
├── po/
├── src/
│   ├── main.vala
│   ├── application.vala
│   ├── window.vala
│   ├── mpris-manager.vala
│   ├── mpris-player.vala
│   └── meson.build
├── meson.build
├── README.md
├── LICENSE
└── handover.md
```

## MVP v0.1

Implement:

- Detect active MPRIS players on the session bus
- Select first usable player automatically
- Display:
  - track title
  - artist
  - album
  - album art if available
- Controls:
  - previous
  - play / pause
  - next
- Update UI when metadata changes
- Small libadwaita window
- Basic Meson build
- Working `.desktop` file

## v0.2

Add:

- Player chooser if multiple MPRIS players are available
- Progress bar
- Current position / duration
- Seek support if player supports `CanSeek`
- Poll position periodically while playing
- Disable unsupported buttons according to MPRIS capabilities

## v0.3

Add:

- Compact mode
- Remember window size and position if possible
- Always-on-top option if GTK/Wayland support permits it
- Keyboard shortcuts
- Better empty state when no player is running

## v1.0

Add:

- AppStream metadata
- Icons
- Screenshots
- Translations
- Flatpak manifest
- Debian packaging
- CI build workflow

## MPRIS basics

MPRIS players usually appear on the session bus as:

```text
org.mpris.MediaPlayer2.<player-name>
```

Important object path:

```text
/org/mpris/MediaPlayer2
```

Important interfaces:

```text
org.mpris.MediaPlayer2
org.mpris.MediaPlayer2.Player
org.freedesktop.DBus.Properties
```

Important player properties:

```text
Metadata
PlaybackStatus
Position
CanGoNext
CanGoPrevious
CanPlay
CanPause
CanSeek
```

Important player methods:

```text
PlayPause()
Play()
Pause()
Next()
Previous()
Seek(x offset)
SetPosition(o track_id, x position)
```

Listen for:

```text
org.freedesktop.DBus.Properties.PropertiesChanged
```

## Metadata keys

Common metadata fields:

```text
xesam:title
xesam:artist
xesam:album
mpris:artUrl
mpris:length
mpris:trackid
```

Notes:

- `xesam:artist` is usually an array of strings.
- `mpris:length` is in microseconds.
- `Position` is also in microseconds.
- `mpris:artUrl` may be a `file://` URI or another URI.
- Handle missing metadata gracefully.

## Design direction

The UI should be simple and daily-use friendly:

```text
┌──────────────────────────────────────┐
│ [Cover]  Track Title                 │
│          Artist                      │
│          Album                       │
│                                      │
│          ───────●────────  2:15      │
│          ⏮   ⏯   ⏭        Player ▼  │
└──────────────────────────────────────┘
```

Use libadwaita widgets and GNOME conventions.

## Build commands

Expected local development flow:

```bash
meson setup build
meson compile -C build
./build/src/mpris-miniplayer
```

Install locally:

```bash
sudo meson install -C build
```

Uninstall during development if supported:

```bash
sudo ninja -C build uninstall
```

## Suggested Debian dependencies

Likely packages:

```bash
sudo apt install \
  meson ninja-build valac \
  libgtk-4-dev libadwaita-1-dev \
  gettext desktop-file-utils appstream-util
```

Package names may need adjustment depending on Debian version.

## Implementation notes for Codex

Start by creating a minimal compiling GTK4/libadwaita Vala app.

Then implement MPRIS in layers:

1. `MprisManager`
   - watches `org.freedesktop.DBus`
   - lists names starting with `org.mpris.MediaPlayer2.`
   - emits signal when players appear/disappear

2. `MprisPlayer`
   - wraps one bus name
   - exposes metadata and capabilities as Vala properties
   - calls MPRIS methods
   - listens to `PropertiesChanged`

3. `Window`
   - binds to active `MprisPlayer`
   - updates labels/buttons/artwork
   - provides player chooser later

Keep code clean and small.
Prefer explicit error handling.
Do not crash when no player is running.
Do not assume one specific media player.

## Important product decision

This is a generic MPRIS mini player, not a Sidra feature.

Sidra triggered the idea because it has no mini player, but the app should be useful for any Linux MPRIS client.
