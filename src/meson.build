config_data = configuration_data()
config_data.set_quoted('GETTEXT_PACKAGE', gettext_package)
config_data.set_quoted('LOCALEDIR', get_option('prefix') / localedir)

config_vala = configure_file(
  input: 'config.vala.in',
  output: 'config.vala',
  configuration: config_data,
)

executable(
  'mpris-miniplayer',
  [
    config_vala,
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
  c_args: [
    '-DGETTEXT_PACKAGE="@0@"'.format(gettext_package),
  ],
  install: true,
  install_dir: get_option('bindir'),
)
