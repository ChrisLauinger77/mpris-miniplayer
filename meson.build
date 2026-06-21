project(
  'mpris-miniplayer',
  ['vala', 'c'],
  version: '0.2.0',
  license: 'GPL-3.0-or-later',
  meson_version: '>= 0.59.0',
)

gnome = import('gnome')
i18n = import('i18n')

app_id = 'io.github.ChrisLauinger.MprisMiniPlayer'
gettext_package = 'mpris-miniplayer'
bindir = get_option('bindir')
datadir = get_option('datadir')
localedir = get_option('localedir')

subdir('src')
subdir('data')
subdir('po')

gnome.post_install(
  glib_compile_schemas: true,
  gtk_update_icon_cache: true,
  update_desktop_database: true,
)
