fs = import('fs')

desktop_data = configuration_data()
desktop_data.set('EXEC_PATH', desktop_exec_path)

desktop_file = configure_file(
  input: app_id + '.desktop.in',
  output: app_id + '.desktop.in',
  configuration: desktop_data,
)

i18n.merge_file(
  input: desktop_file,
  output: app_id + '.desktop',
  type: 'desktop',
  po_dir: '../po',
  install: true,
  install_dir: datadir / 'applications',
)

i18n.merge_file(
  input: configure_file(
    input: app_id + '.metainfo.xml.in',
    output: app_id + '.metainfo.xml.in',
    configuration: {
      'RELEASES': fs.read(app_id + '.releases.xml'),
    },
  ),
  output: app_id + '.metainfo.xml',
  po_dir: '../po',
  install: true,
  install_dir: datadir / 'metainfo',
)

gnome.compile_resources(
  app_id + '.resources',
  app_id + '.gresource.xml',
  source_dir: '.',
)

install_data(
  app_id + '.gschema.xml',
  install_dir: datadir / 'glib-2.0' / 'schemas',
)

gnome.compile_schemas(
  depend_files: files(app_id + '.gschema.xml'),
)

install_data(
  'icons' / (app_id + '.svg'),
  install_dir: datadir / 'icons' / 'hicolor' / 'scalable' / 'apps',
)
