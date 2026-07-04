namespace MprisMiniPlayer {
    public class PreferencesWindow : Adw.PreferencesWindow {
        private AppSettings app_settings;
        private Adw.SwitchRow notification_row;
        private Adw.SwitchRow autostart_row;
        private Adw.SwitchRow automatic_visibility_row;
        private Adw.SwitchRow compact_mode_row;
        private Adw.SwitchRow album_tint_row;
        private Adw.SwitchRow status_indicator_row;
        private StatusIndicator? status_indicator;

        public PreferencesWindow(Gtk.Application app, AppSettings app_settings, StatusIndicator? status_indicator) {
            Object(
                application: app,
                title: _("Preferences"),
                default_width: 420,
                default_height: 360
            );

            this.app_settings = app_settings;
            this.status_indicator = status_indicator;

            build_ui();
            app_settings.changed.connect(sync_rows);
            if (status_indicator != null) {
                status_indicator.support_changed.connect(() => sync_rows("show-status-indicator"));
            }
        }

        private void build_ui() {
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
                if (app_settings.start_on_login != autostart_row.active) {
                    app_settings.start_on_login = autostart_row.active;
                }
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

            album_tint_row = new Adw.SwitchRow();
            album_tint_row.title = _("Tint with album color");
            album_tint_row.subtitle = _("Use a color from the current album cover");
            album_tint_row.active = app_settings.tint_with_album_color;
            album_tint_row.notify["active"].connect(() => {
                app_settings.tint_with_album_color = album_tint_row.active;
            });
            behavior_group.add(album_tint_row);

            status_indicator_row = new Adw.SwitchRow();
            status_indicator_row.title = _("Status indicator");
            status_indicator_row.active = app_settings.show_status_indicator;
            status_indicator_row.notify["active"].connect(() => {
                if (status_indicator_is_supported()) {
                    app_settings.show_status_indicator = status_indicator_row.active;
                }
            });
            behavior_group.add(status_indicator_row);
            sync_status_indicator_row();
        }

        private void sync_rows(string key) {
            notification_row.active = app_settings.show_background_notification;
            autostart_row.active = app_settings.start_on_login;
            automatic_visibility_row.active = app_settings.automatic_window_visibility;
            compact_mode_row.active = app_settings.compact_mode;
            album_tint_row.active = app_settings.tint_with_album_color;
            sync_status_indicator_row();
        }

        private void sync_status_indicator_row() {
            bool supported = status_indicator_is_supported();
            status_indicator_row.sensitive = supported;
            status_indicator_row.active = supported && app_settings.show_status_indicator;
            status_indicator_row.subtitle = supported
                ? _("Show an indicator when the app is running")
                : _("Not supported by this desktop");
        }

        private bool status_indicator_is_supported() {
            return status_indicator != null && status_indicator.supported;
        }
    }
}
