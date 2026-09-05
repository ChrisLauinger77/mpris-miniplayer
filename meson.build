project(
  'mpris-miniplayer',
  ['vala', 'c'],
  version: '2.0.0',
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
    'src/mpris-transport.vala',
    'src/mpris-player.vala',
    'tests/status-menu-test.vala',
  ],
  dependencies: dependency('gio-2.0'),
  vala_args: ['--target-glib=2.66'],
  c_args: ['-DGETTEXT_PACKAGE="@0@"'.format(gettext_package)],
)

test('status menu window actions', status_menu_test)

mpris_player_test = executable(
  'mpris-player-test',
  [
    'src/mpris-transport.vala',
    'src/mpris-player.vala',
    'tests/mpris-player-test.vala',
  ],
  dependencies: dependency('gio-2.0'),
  vala_args: ['--target-glib=2.66'],
  c_args: ['-DGETTEXT_PACKAGE="@0@"'.format(gettext_package)],
)

test('MPRIS player state and queue', mpris_player_test)

gnome.post_install(
  glib_compile_schemas: true,
  gtk_update_icon_cache: true,
  update_desktop_database: true,
)

# Always use a private bus: these tests must never discover or control real players.
dbus_run_session = find_program('dbus-run-session')
mpris_dbus_test = executable(
  'mpris-dbus-test',
  ['src/mpris-transport.vala', 'src/mpris-player.vala', 'src/mpris-manager.vala', 'src/background-portal.vala', 'src/status-indicator.vala', 'tests/mpris-dbus-test.vala'],
  dependencies: dependency('gio-2.0'),
  vala_args: ['--target-glib=2.66'],
  c_args: ['-DGETTEXT_PACKAGE="@0@"'.format(gettext_package)],
)
test('MPRIS D-Bus lifecycle', dbus_run_session, args: ['--', mpris_dbus_test], suite: 'dbus', timeout: 60)

artwork_test = executable(
  'artwork-test',
  ['src/artwork-loader.vala', 'tests/artwork-test.vala', 'tests/artwork-decoder-fault.c'],
  dependencies: [dependency('gio-2.0'), dependency('gdk-pixbuf-2.0'), dependency('libsoup-3.0')],
  vala_args: ['--target-glib=2.66'],
  link_args: ['-Wl,--wrap=gdk_pixbuf_loader_new', '-Wl,--wrap=gdk_pixbuf_loader_write_bytes'],
)
test('Artwork ownership and source changes', artwork_test)

desktop_state_test = executable(
  'desktop-state-test',
  [config_vala, 'src/app-settings.vala', 'src/background-portal.vala', 'tests/desktop-state-test.vala'],
  dependencies: dependency('gio-2.0'),
  vala_args: ['--target-glib=2.66'],
  c_args: ['-DGETTEXT_PACKAGE="@0@"'.format(gettext_package)],
)
test('Autostart and portal state', desktop_state_test)
