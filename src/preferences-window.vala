namespace MprisMiniPlayer {
    private class IgnoredPlayerRow : Object {
        private string application_id;
        private Gtk.Image icon = new Gtk.Image();
        public Adw.SwitchRow widget { get; private set; }
        public signal void toggled(string id, bool ignored);

        public IgnoredPlayerRow(string application_id) {
            this.application_id = application_id;
            widget = new Adw.SwitchRow();
            widget.set_data<string>("application-id", application_id);
            widget.use_markup = false;
            icon.pixel_size = 24;
            widget.add_prefix(icon);
            widget.notify["active"].connect(on_active_changed);
        }

        private void on_active_changed() {
            toggled(application_id, widget.active);
        }

        public void update(MprisApplication app, bool ignored) {
            widget.title = app.display_name;
            widget.subtitle = app.running ? app.id : _("%s (not running)").printf(app.id);
            icon.icon_name = app.icon_name;
            widget.active = ignored;
        }
    }

    public class PreferencesWindow : Adw.PreferencesWindow {
        private AppSettings app_settings;
        private MprisManager manager;
        private Adw.PreferencesGroup ignored_players_group;
        private Gtk.ListBox ignored_players_list;
        private Adw.ActionRow no_players_row;
        private HashTable<string, IgnoredPlayerRow> ignored_player_rows =
            new HashTable<string, IgnoredPlayerRow>(str_hash, str_equal);
        private bool syncing_players = false;
        private Adw.SwitchRow notification_row;
        private Adw.SwitchRow autostart_row;
        private Adw.SwitchRow automatic_visibility_row;
        private Adw.SwitchRow compact_mode_row;
        private Adw.SwitchRow album_tint_row;
        private Adw.SwitchRow status_indicator_row;
        private Adw.SwitchRow keep_queue_open_row;
        private StatusIndicator? status_indicator;

        public PreferencesWindow(Gtk.Application app, AppSettings app_settings, StatusIndicator? status_indicator,
            MprisManager manager) {
            Object(
                application: app,
                title: _("Preferences"),
                default_width: 420,
                default_height: 360
            );

            this.app_settings = app_settings;
            this.status_indicator = status_indicator;
            this.manager = manager;

            build_ui();
            app_settings.changed.connect(sync_rows);
            manager.applications_changed.connect(sync_ignored_players);
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

            keep_queue_open_row = new Adw.SwitchRow();
            keep_queue_open_row.title = _("Keep player queue open");
            keep_queue_open_row.subtitle = _("Keep the queue in the player window open after selecting a track");
            keep_queue_open_row.active = app_settings.keep_queue_open;
            keep_queue_open_row.notify["active"].connect(() => {
                app_settings.keep_queue_open = keep_queue_open_row.active;
            });
            behavior_group.add(keep_queue_open_row);

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

            ignored_players_group = new Adw.PreferencesGroup();
            ignored_players_group.title = _("Ignored players");
            ignored_players_group.description = _("Ignore all instances of these players. Changes apply immediately.");
            page.add(ignored_players_group);

            ignored_players_list = new Gtk.ListBox();
            ignored_players_list.selection_mode = Gtk.SelectionMode.NONE;
            ignored_players_list.add_css_class("boxed-list");
            ignored_players_list.set_sort_func(compare_ignored_rows);
            ignored_players_group.add(ignored_players_list);

            no_players_row = new Adw.ActionRow();
            no_players_row.title = _("No players found");
            no_players_row.subtitle = _("Open a media player to add it to this list.");
            no_players_row.sensitive = false;
            ignored_players_list.append(no_players_row);
            sync_ignored_players();
        }

        private static int compare_ignored_rows(Gtk.ListBoxRow first, Gtk.ListBoxRow second) {
            return strcmp(first.get_data<string>("application-id") ?? "", second.get_data<string>("application-id") ?? "");
        }

        private void sync_ignored_players() {
            syncing_players = true;
            var applications = manager.list_applications();
            var present = new HashTable<string, bool>(str_hash, str_equal);
            foreach (var application in applications) present.insert(application.id, true);
            foreach (var id in ignored_player_rows.get_keys()) {
                if (!present.contains(id)) {
                    ignored_players_list.remove(ignored_player_rows.lookup(id).widget);
                    ignored_player_rows.remove(id);
                }
            }
            foreach (var application in applications) {
                var row = ignored_player_rows.lookup(application.id);
                if (row == null) {
                    row = new IgnoredPlayerRow(application.id);
                    row.toggled.connect(on_ignored_player_toggled);
                    ignored_player_rows.insert(application.id, row);
                    ignored_players_list.append(row.widget);
                }
                row.update(application, manager.is_blacklisted(application.id));
            }
            no_players_row.visible = applications.length == 0;
            syncing_players = false;
        }

        private void on_ignored_player_toggled(string application_id, bool active) {
            if (syncing_players) return;
            // Deferred: the resulting catalog update can remove this very row
            // (an offline player that is no longer ignored).
            app_settings.queue_player_ignored(application_id, active);
        }

        private void sync_rows(string key) {
            // The manager publishes one catalog update after applying an ignore
            // change; these settings do not affect the behavior switches.
            if (key == "blacklisted-players" || key == "blacklisted-player-details") return;
            notification_row.active = app_settings.show_background_notification;
            autostart_row.active = app_settings.start_on_login;
            automatic_visibility_row.active = app_settings.automatic_window_visibility;
            compact_mode_row.active = app_settings.compact_mode;
            album_tint_row.active = app_settings.tint_with_album_color;
            keep_queue_open_row.active = app_settings.keep_queue_open;
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
