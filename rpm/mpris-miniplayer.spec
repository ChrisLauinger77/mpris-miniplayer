%{!?pkg_version:%global pkg_version 2.0.0}

Name:           mpris-miniplayer
Version:        %{pkg_version}
Release:        1%{?dist}
Summary:        Small MPRIS media player controller

License:        GPL-3.0-or-later
URL:            https://github.com/ChrisLauinger77/mpris-miniplayer
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  desktop-file-utils
BuildRequires:  gettext
BuildRequires:  meson
BuildRequires:  pkgconfig(gdk-pixbuf-2.0)
BuildRequires:  pkgconfig(gio-2.0)
BuildRequires:  pkgconfig(gtk4)
BuildRequires:  pkgconfig(libadwaita-1) >= 1.5
BuildRequires:  pkgconfig(libsoup-3.0)
BuildRequires:  vala

%description
MPRIS MiniPlayer is a compact GTK4 and libadwaita controller for Linux media
players that expose the MPRIS interface on the session D-Bus.

%prep
%autosetup

%build
%meson
%meson_build

%install
%meson_install
%find_lang %{name}

%check
desktop-file-validate %{buildroot}%{_datadir}/applications/io.github.ChrisLauinger.MprisMiniPlayer.desktop

%files -f %{name}.lang
%license LICENSE
%doc README.md
%{_bindir}/mpris-miniplayer
%{_datadir}/applications/io.github.ChrisLauinger.MprisMiniPlayer.desktop
%{_datadir}/glib-2.0/schemas/io.github.ChrisLauinger.MprisMiniPlayer.gschema.xml
%{_datadir}/icons/hicolor/scalable/apps/io.github.ChrisLauinger.MprisMiniPlayer.svg
%{_datadir}/icons/hicolor/scalable/status/io.github.ChrisLauinger.MprisMiniPlayer-symbolic.svg
%{_datadir}/metainfo/io.github.ChrisLauinger.MprisMiniPlayer.metainfo.xml

%changelog
* Thu Sep 03 2026 Christian Lauinger <chrislauinger77@users.noreply.github.com> - 2.0.0-1
- Add synchronized shuffle and repeat controls
- Add adaptive MPRIS TrackList queues to the player and status indicator
- Add a preference to keep the player queue open after track selection
- Refresh the application and symbolic status indicator icons

* Tue Sep 01 2026 Christian Lauinger <chrislauinger77@users.noreply.github.com> - 1.5.3-1
- Use a monochrome symbolic icon for the status indicator
- Identify MPRIS MiniPlayer in the status indicator Show and Hide actions

* Fri Aug 28 2026 Christian Lauinger <chrislauinger77@users.noreply.github.com> - 1.5.2-1
- Load remote, local, and embedded MPRIS artwork reliably
- Bound artwork downloads and decoded images

* Mon Aug 24 2026 Christian Lauinger <chrislauinger77@users.noreply.github.com> - 1.5.1-1
- Restore title-bar-minimized windows on the first status indicator Show action

* Sun Aug 16 2026 Christian Lauinger <chrislauinger77@users.noreply.github.com> - 1.5.0-1
- Show the appropriate window visibility action in the status indicator
- Restore minimized or suspended windows from the status indicator

* Sat Aug 15 2026 Christian Lauinger <chrislauinger77@users.noreply.github.com> - 1.4.2-1
- Show a fallback icon when album artwork is unavailable

* Sat Aug 15 2026 Christian Lauinger <chrislauinger77@users.noreply.github.com> - 1.4.1-1
- Correct status indicator mouse-wheel direction and cap upward adjustment
- Preserve amplified volume while lowering it incrementally
- Show a status indicator link when a newer stable release is available

* Sat Aug 15 2026 Christian Lauinger <chrislauinger77@users.noreply.github.com> - 1.4.0-1
- Add track information and media controls to the status indicator
- Add mouse-wheel volume adjustment with temporary icon feedback

* Sat Jul 18 2026 Christian Lauinger <chrislauinger77@users.noreply.github.com> - 1.3.3-1
- Add RPM packaging
