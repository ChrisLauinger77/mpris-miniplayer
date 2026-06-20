executable(
  'mpris-miniplayer',
  [
    'main.vala',
    'application.vala',
    'window.vala',
    'mpris-manager.vala',
    'mpris-player.vala',
  ],
  dependencies: [
    dependency('gtk4'),
    dependency('libadwaita-1'),
    dependency('gio-2.0'),
  ],
  vala_args: [
    '--target-glib=2.66',
    '--gresources', meson.project_source_root() / 'data' / app_id + '.gresource.xml',
  ],
  install: true,
  install_dir: get_option('bindir'),
)
