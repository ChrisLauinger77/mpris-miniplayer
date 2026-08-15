project(
  'mpris-miniplayer',
  ['vala', 'c'],
  version: '1.4.2',
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
exec_path = get_option('prefix') / bindir / 'mpris-miniplayer'
desktop_exec_path = '"' + exec_path.replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$') + '"'

subdir('src')
subdir('data')
subdir('po')

update_checker_test = executable(
  'update-checker-test',
  [
    config_vala,
    'src/update-checker.vala',
    'tests/update-checker-test.vala',
  ],
  dependencies: dependency('libsoup-3.0'),
  vala_args: ['--target-glib=2.66'],
)

test('update checker version comparison', update_checker_test)

status_menu_test = executable(
  'status-menu-test',
  [
    'src/status-indicator.vala',
    'src/mpris-player.vala',
    'tests/status-menu-test.vala',
  ],
  dependencies: dependency('gio-2.0'),
  vala_args: ['--target-glib=2.66'],
  c_args: ['-DGETTEXT_PACKAGE="@0@"'.format(gettext_package)],
)

test('status menu window actions', status_menu_test)

gnome.post_install(
  glib_compile_schemas: true,
  gtk_update_icon_cache: true,
  update_desktop_database: true,
)
