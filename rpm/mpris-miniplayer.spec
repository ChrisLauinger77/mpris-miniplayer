%{!?pkg_version:%global pkg_version 1.3.3}

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
%{_datadir}/metainfo/io.github.ChrisLauinger.MprisMiniPlayer.metainfo.xml

%changelog
* Sat Jul 18 2026 Christian Lauinger <chrislauinger77@users.noreply.github.com> - 1.3.3-1
- Add RPM packaging
