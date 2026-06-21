namespace MprisMiniPlayer {
    public class Application : Adw.Application {
        private const string BACKGROUND_NOTIFICATION_ID = "background";

        private AppSettings app_settings;
        private BackgroundPortal background_portal;
        private MprisManager? manager;
        private Window? main_window;
        private PreferencesWindow? preferences_window;
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
            background_portal = new BackgroundPortal();
            setup_actions();

            try {
                manager = new MprisManager();
                manager.players_changed.connect(on_players_changed);
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

            var preferences_action = new SimpleAction("preferences", null);
            preferences_action.activate.connect(() => present_preferences());
            add_action(preferences_action);

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
                present_window();
            } else if (main_window != null) {
                main_window.set_visible(false);
                enter_background();
            }
        }

        private bool has_players() {
            return manager != null && manager.list_players().length > 0;
        }

        private void present_window() {
            if (main_window == null) {
                main_window = new Window(this, manager);
                main_window.close_request.connect(() => {
                    main_window.set_visible(false);
                    enter_background();
                    return true;
                });
            }

            main_window.refresh_players();
            main_window.present();
            background_portal.leave_background();
            withdraw_notification(BACKGROUND_NOTIFICATION_ID);
        }

        private void present_preferences() {
            if (preferences_window == null) {
                preferences_window = new PreferencesWindow(this, app_settings);
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

            if (held) {
                release();
                held = false;
            }

            quit();
        }
    }
}
