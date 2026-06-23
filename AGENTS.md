# AGENTS.md

Instructions for coding agents working on MPRIS MiniPlayer.

## Project

MPRIS MiniPlayer is a standalone Linux mini player for media players that expose MPRIS on the session D-Bus.

- App name: `MPRIS MiniPlayer`
- App ID: `io.github.ChrisLauinger.MprisMiniPlayer`
- Executable: `mpris-miniplayer`
- Desktop file: `io.github.ChrisLauinger.MprisMiniPlayer.desktop`
- AppStream file: `io.github.ChrisLauinger.MprisMiniPlayer.metainfo.xml`
- License: GPL-3.0-or-later

This is a generic MPRIS client. Do not make it Sidra-specific, even though Sidra inspired the original idea.

Target players include Sidra, VLC, mpv with an MPRIS plugin, Spotify, Strawberry, Rhythmbox, Elisa, browsers exposing media sessions, Mopidy, spotifyd, and similar clients.

## Stack

Use the existing stack:

- Vala
- GTK4
- libadwaita
- Gio / GDBus
- Meson

Do not rewrite the long-term implementation in Python. Do not use raylib or imgui.

## Repository Layout

```text
mpris-miniplayer/
├── data/
│   ├── io.github.ChrisLauinger.MprisMiniPlayer.desktop.in
│   ├── io.github.ChrisLauinger.MprisMiniPlayer.gresource.xml
│   ├── io.github.ChrisLauinger.MprisMiniPlayer.metainfo.xml.in
│   └── meson.build
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
└── AGENTS.md
```

## Build And Validation

Expected local development flow:

```bash
meson setup build
meson compile -C build
./build/src/mpris-miniplayer
```

Useful validation commands:

```bash
desktop-file-validate build/data/io.github.ChrisLauinger.MprisMiniPlayer.desktop
appstreamcli validate --no-net build/data/io.github.ChrisLauinger.MprisMiniPlayer.metainfo.xml
```

Install locally:

```bash
sudo meson install -C build
```

Uninstall during development if supported:

```bash
sudo ninja -C build uninstall
```

Typical Debian dependencies:

```bash
sudo apt install \
  meson ninja-build valac \
  libgtk-4-dev libadwaita-1-dev \
  gettext desktop-file-utils appstream-util
```

Package names may need adjustment by distribution and version.

## Release Version Checklist

When preparing a new release, update the version in:

- `meson.build`: project version.
- `data/io.github.ChrisLauinger.MprisMiniPlayer.metainfo.xml.in`: add a new top `<release>` entry with the new version and release date.
- `debian/changelog`: add a new Debian changelog entry, usually `<upstream-version>-1` for a new upstream release.
- `debian/mpris-miniplayer.1`: update the manpage header version string.

Then tag the release with a `v` prefix, for example:

```bash
git tag v1.1.0
git push origin v1.1.0
```

The release workflow uses the Git tag for the uploaded Flatpak and Debian package asset names.

## MPRIS Notes

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

Common metadata fields:

```text
xesam:title
xesam:artist
xesam:album
mpris:artUrl
mpris:length
mpris:trackid
```

Metadata details:

- `xesam:artist` is usually an array of strings.
- `mpris:length` is in microseconds.
- `Position` is also in microseconds.
- `mpris:artUrl` may be a `file://` URI or another URI.
- Handle missing metadata gracefully.

## Implementation Guidance

Keep the code small, explicit, and aligned with GNOME conventions.

- `MprisManager` watches `org.freedesktop.DBus`, lists names starting with `org.mpris.MediaPlayer2.`, and emits a signal when players appear or disappear.
- `MprisPlayer` wraps one bus name, exposes metadata and capabilities as Vala properties, calls MPRIS methods, and listens to `PropertiesChanged`.
- `Window` binds to the active `MprisPlayer`, updates labels/buttons/artwork, and should eventually provide a player chooser.

Do not crash when no player is running. Do not assume one specific media player.

## UI Direction

The UI should be compact, polished, and useful every day:

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

Use libadwaita widgets and GNOME interaction patterns.
