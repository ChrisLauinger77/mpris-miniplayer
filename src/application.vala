namespace MprisMiniPlayer {
    public class Application : Adw.Application {
        private const string BACKGROUND_NOTIFICATION_ID = "background";

        private AppSettings app_settings;
        private BackgroundPortal background_portal;
        private StatusIndicator status_indicator;
        private MprisManager? manager;
        private Window? main_window;
        private PreferencesWindow? preferences_window;
        private Adw.AboutDialog? about_dialog;
        private SimpleAction? compact_mode_action;
        private bool suppress_next_start_on_login_portal_update = false;
        private bool startup_activation_handled = false;
        private bool held = false;

        public Application() {
            Object(
                application_id: "io.github.ChrisLauinger.MprisMiniPlayer",
                flags: ApplicationFlags.DEFAULT_FLAGS
            );
        }

        protected override void startup() {
            base.startup();

            hold();
            held = true;

            app_settings = new AppSettings();
            app_settings.changed.connect(on_app_settings_changed);
            background_portal = new BackgroundPortal();
            background_portal.autostart_changed.connect(on_portal_autostart_changed);
            setup_actions();
            status_indicator = new StatusIndicator();
            status_indicator.activated.connect(() => present_window());
            status_indicator.action_requested.connect(on_status_indicator_action_requested);
            status_indicator.set_compact_mode(app_settings.compact_mode);
            status_indicator.set_enabled(app_settings.show_status_indicator);

            try {
                manager = new MprisManager();
                manager.players_changed.connect(on_players_changed);
                manager.player_priority_changed.connect(on_player_priority_changed);
            } catch (Error error) {
                warning("Unable to monitor MPRIS players: %s", error.message);
            }
        }

        protected override void activate() {
            if (!startup_activation_handled) {
                startup_activation_handled = true;
                handle_startup_visibility();
                return;
            }

            present_window();
        }

        private void setup_actions() {
            var open_action = new SimpleAction("open", null);
            open_action.activate.connect(() => present_window());
            add_action(open_action);

            var hide_action = new SimpleAction("hide", null);
            hide_action.activate.connect(() => hide_window());
            add_action(hide_action);

            var preferences_action = new SimpleAction("preferences", null);
            preferences_action.activate.connect(() => present_preferences());
            add_action(preferences_action);

            var about_action = new SimpleAction("about", null);
            about_action.activate.connect(() => present_about());
            add_action(about_action);

            compact_mode_action = new SimpleAction.stateful(
                "compact-mode",
                null,
                new Variant.boolean(app_settings.compact_mode)
            );
            compact_mode_action.change_state.connect((value) => {
                bool enabled = value.get_boolean();
                app_settings.compact_mode = enabled;
                compact_mode_action.set_state(new Variant.boolean(enabled));
                if (main_window != null) {
                    main_window.set_compact_mode(enabled);
                }
            });
            add_action(compact_mode_action);

            var quit_action = new SimpleAction("quit", null);
            quit_action.activate.connect(() => quit_app());
            add_action(quit_action);

            set_accels_for_action("app.quit", { "<Control>q" });
        }

        private void handle_startup_visibility() {
            if (has_players()) {
                present_window();
                return;
            }

            enter_background();
            send_background_notification();
        }

        private void on_players_changed() {
            bool players_available = has_players();

            if (main_window != null) {
                main_window.refresh_players();
            }

            if (!app_settings.automatic_window_visibility) {
                return;
            }

            if (players_available) {
                show_window_automatically();
            } else if (main_window != null) {
                hide_window();
            }
        }

        private void on_player_priority_changed() {
            if (main_window != null) {
                main_window.refresh_players();
            }
        }

        private bool has_players() {
            return manager != null && manager.list_players().length > 0;
        }

        private void present_window() {
            show_window(true);
        }

        private void show_window_automatically() {
            show_window(false);
        }

        private void show_window(bool request_activation) {
            if (main_window == null) {
                main_window = new Window(
                    this,
                    manager,
                    app_settings.compact_mode,
                    app_settings.tint_with_album_color
                );
                main_window.close_request.connect(() => {
                    hide_window();
                    return true;
                });
            }

            main_window.refresh_players();
            if (request_activation) {
                main_window.present();
            } else {
                // A player can appear without user interaction. Requesting focus in
                // that case is rejected by Wayland compositors and may produce an
                // "app is ready" notification instead of showing the window.
                main_window.set_visible(true);
            }
            background_portal.leave_background();
            withdraw_notification(BACKGROUND_NOTIFICATION_ID);
        }

        private void hide_window() {
            if (main_window != null) {
                main_window.set_visible(false);
            }

            enter_background();
        }

        private void present_preferences() {
            if (preferences_window == null) {
                preferences_window = new PreferencesWindow(this, app_settings, status_indicator);
                preferences_window.close_request.connect(() => {
                    preferences_window = null;
                    return false;
                });
            }

            if (main_window != null) {
                preferences_window.transient_for = main_window;
            }

            preferences_window.present();
        }

        private void present_about() {
            if (about_dialog == null) {
                about_dialog = new Adw.AboutDialog();
                about_dialog.application_name = _("MPRIS MiniPlayer");
                about_dialog.application_icon = "io.github.ChrisLauinger.MprisMiniPlayer";
                about_dialog.developer_name = "Chris Lauinger";
                about_dialog.version = Config.VERSION;
                about_dialog.website = "https://github.com/ChrisLauinger77/mpris-miniplayer";
                about_dialog.issue_url = "https://github.com/ChrisLauinger77/mpris-miniplayer/issues";
                about_dialog.license_type = Gtk.License.GPL_3_0;
                about_dialog.content_width = 420;
                about_dialog.content_height = 560;
                about_dialog.closed.connect(() => {
                    about_dialog = null;
                });
            }

            about_dialog.present(null);
        }

        private void on_app_settings_changed(string key) {
            if (key == "start-on-login") {
                if (suppress_next_start_on_login_portal_update) {
                    suppress_next_start_on_login_portal_update = false;
                } else {
                    background_portal.update_autostart(app_settings.start_on_login);
                }
            }

            if (key == "show-status-indicator") {
                status_indicator.set_enabled(app_settings.show_status_indicator);
            }

            bool compact_mode = app_settings.compact_mode;
            if (compact_mode_action != null) {
                compact_mode_action.set_state(new Variant.boolean(compact_mode));
            }
            if (main_window != null) {
                main_window.set_compact_mode(compact_mode);
                main_window.set_album_tint_enabled(app_settings.tint_with_album_color);
            }
            status_indicator.set_compact_mode(compact_mode);
        }

        private void on_portal_autostart_changed(bool enabled) {
            if (app_settings.start_on_login != enabled) {
                suppress_next_start_on_login_portal_update = true;
                app_settings.start_on_login = enabled;
            }
        }

        private void on_status_indicator_action_requested(string action) {
            switch (action) {
                case "show":
                    present_window();
                    break;
                case "hide":
                    hide_window();
                    break;
                case "preferences":
                    present_preferences();
                    break;
                case "about":
                    present_about();
                    break;
                case "compact-mode":
                    app_settings.compact_mode = !app_settings.compact_mode;
                    break;
                case "quit":
                    quit_app();
                    break;
            }
        }

        private void send_background_notification() {
            if (!app_settings.show_background_notification) {
                return;
            }

            var notification = new Notification(_("MPRIS MiniPlayer is running in the background"));
            if (app_settings.automatic_window_visibility) {
                notification.set_body(_("The window will appear automatically when a compatible media player becomes available."));
            } else {
                notification.set_body(_("Open the window when you want to control a compatible media player."));
            }
            notification.add_button(_("Open"), "app.open");

            send_notification(BACKGROUND_NOTIFICATION_ID, notification);
        }

        private void enter_background() {
            background_portal.enter_background(app_settings.start_on_login);
        }

        private void quit_app() {
            withdraw_notification(BACKGROUND_NOTIFICATION_ID);
            background_portal.leave_background();
            status_indicator.shutdown();

            if (held) {
                release();
                held = false;
            }

            quit();
        }
    }
}
