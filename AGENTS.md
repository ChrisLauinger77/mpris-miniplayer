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
│   ├── io.github.ChrisLauinger.MprisMiniPlayer.releases.xml
│   └── meson.build
├── po/
├── rpm/
│   └── mpris-miniplayer.spec
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

Translation maintenance:

```bash
meson compile -C build mpris-miniplayer-pot
meson compile -C build mpris-miniplayer-update-po
msgattrib --untranslated --no-obsolete po/*.po
msgattrib --only-fuzzy --no-obsolete po/*.po
for po_file in po/*.po; do msgfmt --check "$po_file" -o /dev/null; done
```

Keep `po/mpris-miniplayer.pot` up to date when adding, removing, or changing translatable strings. Check both untranslated and fuzzy entries before considering translation work complete.

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
  libsoup-3.0-dev \
  gettext desktop-file-utils appstream-util
```

Package names may need adjustment by distribution and version.

Typical Fedora dependencies for building the application and RPM package:

```bash
sudo dnf install \
  desktop-file-utils gcc gettext git \
  gtk4-devel libadwaita-devel meson \
  libsoup3-devel \
  rpm-build vala
```

To reproduce the release RPM build locally, create the source archive expected by
the spec and pass the upstream version without the tag's `v` prefix:

```bash
version="1.3.3"
mkdir -p "$HOME/rpmbuild/SOURCES"
git archive \
  --format=tar.gz \
  --prefix="mpris-miniplayer-${version}/" \
  --output="$HOME/rpmbuild/SOURCES/mpris-miniplayer-${version}.tar.gz" \
  HEAD
rpmbuild -bb --define "pkg_version ${version}" rpm/mpris-miniplayer.spec
```

## Release Version Checklist

When preparing a new release, update the version in:

- `meson.build`: project version.
- `data/io.github.ChrisLauinger.MprisMiniPlayer.releases.xml`: add a new top `<release>` entry with the new version and release date.
- `debian/changelog`: add a new Debian changelog entry, usually `<upstream-version>-1` for a new upstream release.
- `debian/mpris-miniplayer.1`: update the manpage header version string.
- `rpm/mpris-miniplayer.spec`: update the fallback `pkg_version` and add a new top `%changelog` entry.

Do not translate AppStream release notes. Keep release entries in `data/io.github.ChrisLauinger.MprisMiniPlayer.releases.xml`, which is intentionally not listed in `po/POTFILES`; release-note strings should never be added to `po/mpris-miniplayer.pot` or `po/*.po`.

Releases are built once and published from that tested build in a single manual run:

1. After the version changes are on `main`, run the `Release` workflow manually
   (`workflow_dispatch`) on `main`. It builds the Flatpak, Debian, and RPM packages,
   writes `SHA256SUMS`, and uploads everything as the `release-assets` artifact.
   The `Publish release` job waits for approval through the `release` environment;
   the build stage never creates a tag or release.
2. Download and test the artifact linked in the run's job summary. In the workflow
   run, click `Review deployments`, select `release`, and choose `Approve and deploy`
   to publish or `Reject` to fail the workflow without creating a tag or release.
3. After approval, the publishing job downloads that run's artifact by its immutable
   ID, checks the original `SHA256SUMS`, creates an annotated `v`-prefixed tag at the
   built commit with a `Candidate-Run: <run ID>` line, and publishes those exact files.
   It does not rebuild. If publishing fails, rerun only the failed `Publish release`
   job and approve it again: it verifies any existing tag points at the built commit,
   deletes the draft its earlier attempt left, and uploads the verified files again,
   or succeeds without changes if the release was already published with exactly
   those files. Tag pushes do not trigger the workflow.

The `release` environment must require the maintainer's review and allow `main`.
Keep `Prevent self-review` disabled when the maintainer both starts and approves runs.
Candidate artifacts expire after 30 days. If a build fails, a candidate expires, or new
packages are needed, start a new manual run instead of rerunning build jobs. Candidate
tooling lives in `tools/release_candidate.py` with tests in `tests/test_release_candidate.py`.

The release workflow removes the tag's `v` prefix for the RPM package metadata.
It uses the full Git tag in the uploaded Flatpak, Debian, and RPM asset names.

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
