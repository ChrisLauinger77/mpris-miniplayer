namespace MprisMiniPlayer {
    public class PreferencesWindow : Adw.PreferencesWindow {
        private AppSettings app_settings;
        private Adw.SwitchRow notification_row;
        private Adw.SwitchRow autostart_row;
        private Adw.SwitchRow automatic_visibility_row;
        private Adw.SwitchRow compact_mode_row;

        public PreferencesWindow(Gtk.Application app, AppSettings app_settings) {
            Object(
                application: app,
                title: _("Preferences"),
                default_width: 420,
                default_height: 360
            );

            this.app_settings = app_settings;

            build_ui(app);
            app_settings.changed.connect(sync_rows);
        }

        private void build_ui(Gtk.Application app) {
            var page = new Adw.PreferencesPage();
            page.title = _("Preferences");
            add(page);

            var behavior_group = new Adw.PreferencesGroup();
            behavior_group.title = _("Behavior");
            page.add(behavior_group);

            automatic_visibility_row = new Adw.SwitchRow();
            automatic_visibility_row.title = _("Show and hide automatically");
            automatic_visibility_row.subtitle = _("Show the window when a player appears and hide it when none remain");
            automatic_visibility_row.active = app_settings.automatic_window_visibility;
            automatic_visibility_row.notify["active"].connect(() => {
                app_settings.automatic_window_visibility = automatic_visibility_row.active;
            });
            behavior_group.add(automatic_visibility_row);

            notification_row = new Adw.SwitchRow();
            notification_row.title = _("Background notification");
            notification_row.subtitle = _("Notify when the app starts hidden in the background");
            notification_row.active = app_settings.show_background_notification;
            notification_row.notify["active"].connect(() => {
                app_settings.show_background_notification = notification_row.active;
            });
            behavior_group.add(notification_row);

            autostart_row = new Adw.SwitchRow();
            autostart_row.title = _("Start on login");
            autostart_row.subtitle = _("Start MPRIS MiniPlayer automatically when you log in");
            autostart_row.active = app_settings.start_on_login;
            autostart_row.notify["active"].connect(() => {
                app_settings.start_on_login = autostart_row.active;
            });
            behavior_group.add(autostart_row);

            compact_mode_row = new Adw.SwitchRow();
            compact_mode_row.title = _("Compact mode");
            compact_mode_row.subtitle = _("Use a smaller window layout");
            compact_mode_row.active = app_settings.compact_mode;
            compact_mode_row.notify["active"].connect(() => {
                app_settings.compact_mode = compact_mode_row.active;
            });
            behavior_group.add(compact_mode_row);

            var app_group = new Adw.PreferencesGroup();
            app_group.title = _("Application");
            page.add(app_group);

            var about_row = new Adw.ActionRow();
            about_row.title = _("About MPRIS MiniPlayer");
            about_row.activatable = true;
            about_row.activated.connect(() => app.activate_action("about", null));

            var about_icon = new Gtk.Image.from_icon_name("help-about-symbolic");
            about_icon.valign = Gtk.Align.CENTER;
            about_row.add_prefix(about_icon);

            var about_arrow = new Gtk.Image.from_icon_name("go-next-symbolic");
            about_arrow.valign = Gtk.Align.CENTER;
            about_row.add_suffix(about_arrow);
            app_group.add(about_row);

            var quit_row = new Adw.ActionRow();
            quit_row.title = _("Quit MPRIS MiniPlayer");
            quit_row.subtitle = _("Stop running in the background");

            var quit_button = new Gtk.Button.with_label(_("Quit"));
            quit_button.valign = Gtk.Align.CENTER;
            quit_button.add_css_class("destructive-action");
            quit_button.clicked.connect(() => app.activate_action("quit", null));
            quit_row.add_suffix(quit_button);
            quit_row.activatable_widget = quit_button;
            app_group.add(quit_row);
        }

        private void sync_rows(string key) {
            notification_row.active = app_settings.show_background_notification;
            autostart_row.active = app_settings.start_on_login;
            automatic_visibility_row.active = app_settings.automatic_window_visibility;
            compact_mode_row.active = app_settings.compact_mode;
        }
    }
}
