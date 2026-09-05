namespace MprisMiniPlayer {
    public class Application : Adw.Application {
        private const string BACKGROUND_NOTIFICATION_ID = "background";

        private AppSettings app_settings;
        private BackgroundPortal background_portal;
        private StatusIndicator status_indicator;
        private UpdateChecker? update_checker;
        private MprisManager? manager;
        private Window? main_window;
        private Gdk.Toplevel? main_toplevel;
        private ulong main_toplevel_state_handler_id = 0;
        private uint restore_minimized_source_id = 0;
        private PreferencesWindow? preferences_window;
        private Adw.AboutDialog? about_dialog;
        private SimpleAction? compact_mode_action;
        private SimpleAction? shuffle_action;
        private SimpleAction? repeat_cycle_action;
        private MprisPlayer? action_player;
        private ulong action_player_changed_handler_id = 0;
        private bool suppress_next_start_on_login_portal_update = false;
        private bool startup_activation_handled = false;
        private bool startup_visibility_pending = false;
        private bool update_check_started = false;
        private string latest_release_url = "";
        private bool held = false;
        private bool shutting_down = false;
        private Cancellable lifetime = new Cancellable();

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
            background_portal = new BackgroundPortal(app_settings.start_on_login);
            background_portal.autostart_changed.connect(on_portal_autostart_changed);
            setup_actions();
            status_indicator = new StatusIndicator();
            status_indicator.activated.connect(() => show_window_from_indicator());
            status_indicator.action_requested.connect(on_status_indicator_action_requested);
            status_indicator.support_changed.connect(maybe_start_update_check);
            status_indicator.set_compact_mode(app_settings.compact_mode);
            status_indicator.set_enabled(app_settings.show_status_indicator);
            maybe_start_update_check();

            manager = new MprisManager();
            manager.players_changed.connect(on_players_changed);
            manager.players_updated.connect(() => {
                if (!shutting_down && main_window != null) main_window.refresh_players();
            });
            manager.active_player_changed.connect(on_active_player_changed);
            manager.operation_failed.connect((operation, error) => {
                warning("%s: %s", operation, error.message);
            });
            manager.discovery_finished.connect(() => {
                if (startup_visibility_pending) handle_startup_visibility();
            });
            status_indicator.set_player(manager.active_player);
            bind_player_actions(manager.active_player);
        }

        protected override void activate() {
            if (!startup_activation_handled) {
                startup_activation_handled = true;
                handle_startup_visibility();
                return;
            }

            startup_visibility_pending = false;
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

            shuffle_action = new SimpleAction.stateful(
                "shuffle",
                null,
                new Variant.boolean(false)
            );
            shuffle_action.activate.connect(() => {
                if (action_player != null) {
                    action_player.toggle_shuffle();
                }
            });
            shuffle_action.change_state.connect((value) => {
                if (
                    action_player != null
                    && value.get_boolean() != action_player.shuffle
                ) {
                    action_player.toggle_shuffle();
                }
            });
            shuffle_action.set_enabled(false);
            add_action(shuffle_action);

            repeat_cycle_action = new SimpleAction("repeat-cycle", null);
            repeat_cycle_action.activate.connect(() => {
                if (action_player != null) {
                    action_player.cycle_loop_status();
                }
            });
            repeat_cycle_action.set_enabled(false);
            add_action(repeat_cycle_action);

            var quit_action = new SimpleAction("quit", null);
            quit_action.activate.connect(() => quit_app());
            add_action(quit_action);

            set_accels_for_action("app.quit", { "<Control>q" });
        }

        private void handle_startup_visibility() {
            if (manager != null && !manager.ready) {
                startup_visibility_pending = true;
                return;
            }
            startup_visibility_pending = false;
            if (has_players()) {
                present_window();
                return;
            }

            enter_background();
            send_background_notification();
        }

        private void on_players_changed() {
            if (shutting_down) return;
            bool players_available = has_players();

            if (main_window != null) {
                main_window.refresh_players();
            }

            if (!app_settings.automatic_window_visibility || (manager != null && !manager.ready)) {
                return;
            }

            if (players_available) {
                show_window_automatically();
            } else if (main_window != null) {
                hide_window();
            }
        }

        private void on_active_player_changed() {
            if (shutting_down) return;
            status_indicator.set_player(manager != null ? manager.active_player : null);
            bind_player_actions(manager != null ? manager.active_player : null);
            if (main_window != null) {
                main_window.refresh_players();
            }
        }

        private void bind_player_actions(MprisPlayer? selected_player) {
            if (action_player != null && action_player_changed_handler_id != 0) {
                SignalHandler.disconnect(action_player, action_player_changed_handler_id);
                action_player_changed_handler_id = 0;
            }

            action_player = selected_player;
            if (action_player != null) {
                action_player_changed_handler_id = action_player.changed.connect(sync_player_actions);
            }
            sync_player_actions();
        }

        private void sync_player_actions() {
            bool can_shuffle = action_player != null
                && action_player.has_shuffle
                && action_player.can_control;
            bool can_repeat = action_player != null
                && action_player.has_loop_status
                && action_player.can_control;

            if (shuffle_action != null) {
                shuffle_action.set_enabled(can_shuffle);
                shuffle_action.set_state(new Variant.boolean(
                    action_player != null && action_player.shuffle
                ));
            }
            if (repeat_cycle_action != null) {
                repeat_cycle_action.set_enabled(can_repeat);
            }
        }

        private bool has_players() {
            return manager != null && manager.list_players().length > 0;
        }

        private void present_window() {
            startup_visibility_pending = false;
            show_window(true);
        }

        private void show_window_automatically() {
            show_window(false);
        }

        private void show_window_from_indicator() {
            startup_visibility_pending = false;
            show_window(false, true);
        }

        private void show_window(
            bool request_activation,
            bool restore_minimized = false
        ) {
            clear_restore_minimized_source();
            if (main_window == null) {
                main_window = new Window(
                    this,
                    manager,
                    app_settings.compact_mode,
                    app_settings.tint_with_album_color,
                    app_settings.keep_queue_open
                );
                main_window.close_request.connect(() => {
                    hide_window();
                    return true;
                });
                main_window.notify["visible"].connect(sync_status_indicator_window_state);
                main_window.map.connect(sync_status_indicator_window_state);
                main_window.unmap.connect(sync_status_indicator_window_state);
                ((Gtk.Widget) main_window).realize.connect(track_main_toplevel);
                ((Gtk.Widget) main_window).unrealize.connect(clear_main_toplevel);
            }

            main_window.refresh_players();
            bool restore_suspended_window = restore_minimized
                && main_window.visible
                && is_main_window_suspended();
            if (request_activation) {
                main_window.present();
            } else if (restore_suspended_window) {
                // Wayland does not provide an activation token through the
                // StatusNotifier D-Bus API. Remapping restores a compositor-
                // minimized surface without producing an activation notification.
                // Defer showing it so GTK processes the unmap before the remap.
                main_window.set_visible(false);
                restore_minimized_source_id = Idle.add(() => {
                    restore_minimized_source_id = 0;
                    if (main_window != null) {
                        main_window.unminimize();
                        main_window.set_visible(true);
                    }
                    return Source.REMOVE;
                });
            } else {
                // A player can appear without user interaction. Requesting focus in
                // that case is rejected by Wayland compositors and may produce an
                // "app is ready" notification instead of showing the window.
                main_window.set_visible(true);
                if (restore_minimized) {
                    main_window.unminimize();
                }
            }
            background_portal.leave_background();
            withdraw_notification(BACKGROUND_NOTIFICATION_ID);
        }

        private void track_main_toplevel() {
            clear_main_toplevel();
            if (main_window == null) {
                return;
            }

            main_toplevel = main_window.get_surface() as Gdk.Toplevel;
            if (main_toplevel != null) {
                main_toplevel_state_handler_id =
                    main_toplevel.notify["state"].connect(
                        sync_status_indicator_window_state
                    );
            }
            sync_status_indicator_window_state();
        }

        private void clear_main_toplevel() {
            if (main_toplevel != null && main_toplevel_state_handler_id != 0) {
                SignalHandler.disconnect(main_toplevel, main_toplevel_state_handler_id);
            }
            main_toplevel_state_handler_id = 0;
            main_toplevel = null;
            sync_status_indicator_window_state();
        }

        private void sync_status_indicator_window_state() {
            bool window_shown = main_window != null
                && main_window.visible
                && main_window.get_mapped();
            if (window_shown && is_main_window_suspended()) {
                window_shown = false;
            }

            status_indicator.set_window_shown(window_shown);
        }

        private bool is_main_window_suspended() {
            return main_toplevel != null
                && (
                    main_toplevel.get_state() & (
                        Gdk.ToplevelState.MINIMIZED
                        | Gdk.ToplevelState.SUSPENDED
                    )
                ) != 0;
        }

        private void hide_window() {
            clear_restore_minimized_source();
            if (main_window != null) {
                main_window.set_visible(false);
            }

            enter_background();
        }

        private void clear_restore_minimized_source() {
            if (restore_minimized_source_id == 0) {
                return;
            }

            Source.remove(restore_minimized_source_id);
            restore_minimized_source_id = 0;
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
                maybe_start_update_check();
            }

            bool compact_mode = app_settings.compact_mode;
            if (compact_mode_action != null) {
                compact_mode_action.set_state(new Variant.boolean(compact_mode));
            }
            if (main_window != null) {
                main_window.set_compact_mode(compact_mode);
                main_window.set_album_tint_enabled(app_settings.tint_with_album_color);
                main_window.set_keep_queue_open(app_settings.keep_queue_open);
            }
            status_indicator.set_compact_mode(compact_mode);
        }

        private void on_portal_autostart_changed(bool enabled, bool portal_answered) {
            if (portal_answered) Autostart.remove_legacy_flatpak_entry();
            if (app_settings.start_on_login != enabled) {
                suppress_next_start_on_login_portal_update = true;
                app_settings.start_on_login = enabled;
            }
        }

        private void on_status_indicator_action_requested(string action) {
            switch (action) {
                case "show":
                    show_window_from_indicator();
                    break;
                case "hide":
                    hide_window();
                    break;
                case "open-release":
                    open_latest_release.begin();
                    break;
                case "previous":
                    if (manager != null && manager.active_player != null) {
                        manager.active_player.previous();
                    }
                    break;
                case "play-pause":
                    if (manager != null && manager.active_player != null) {
                        manager.active_player.play_pause();
                    }
                    break;
                case "next":
                    if (manager != null && manager.active_player != null) {
                        manager.active_player.next();
                    }
                    break;
                case "shuffle":
                    if (manager != null && manager.active_player != null) {
                        manager.active_player.toggle_shuffle();
                    }
                    break;
                case "repeat-none":
                    set_active_player_loop_status("None");
                    break;
                case "repeat-track":
                    set_active_player_loop_status("Track");
                    break;
                case "repeat-playlist":
                    set_active_player_loop_status("Playlist");
                    break;
                case "mute":
                    if (manager != null && manager.active_player != null) {
                        manager.active_player.toggle_mute();
                    }
                    break;
                case "volume-25":
                    set_active_player_volume(0.25);
                    break;
                case "volume-50":
                    set_active_player_volume(0.50);
                    break;
                case "volume-75":
                    set_active_player_volume(0.75);
                    break;
                case "volume-100":
                    set_active_player_volume(1.0);
                    break;
                case "volume-up":
                    adjust_active_player_volume(0.05);
                    break;
                case "volume-down":
                    adjust_active_player_volume(-0.05);
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

        private void set_active_player_loop_status(string loop_status) {
            if (manager != null && manager.active_player != null) {
                manager.active_player.change_loop_status(loop_status);
            }
        }

        private void maybe_start_update_check() {
            if (
                update_check_started
                || !app_settings.show_status_indicator
                || !status_indicator.supported
            ) {
                return;
            }

            update_check_started = true;
            update_checker = new UpdateChecker();
            update_checker.update_available.connect((version, release_url) => {
                latest_release_url = release_url;
                status_indicator.set_update_available(version);
            });
            update_checker.check.begin();
        }

        private async void open_latest_release() {
            if (latest_release_url == "") {
                return;
            }

            try {
                yield AppInfo.launch_default_for_uri_async(latest_release_url, null, lifetime);
            } catch (Error error) {
                warning("Unable to open release page: %s", error.message);
            }
        }

        private void set_active_player_volume(double volume) {
            if (manager != null && manager.active_player != null) {
                manager.active_player.set_player_volume(volume);
            }
        }

        private void adjust_active_player_volume(double delta) {
            if (manager != null && manager.active_player != null) {
                manager.active_player.adjust_volume(delta);
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

        protected override void shutdown() {
            shutting_down = true;
            lifetime.cancel();
            clear_restore_minimized_source();
            clear_main_toplevel();
            bind_player_actions(null);
            if (main_window != null) { main_window.shutdown(); main_window.destroy(); main_window = null; }
            if (preferences_window != null) { preferences_window.destroy(); preferences_window = null; }
            if (about_dialog != null) { about_dialog.close(); about_dialog = null; }
            if (status_indicator != null) status_indicator.shutdown();
            if (background_portal != null) background_portal.shutdown();
            if (update_checker != null) update_checker.shutdown();
            if (manager != null) { manager.shutdown(); manager = null; }
            base.shutdown();
        }

        private void quit_app() {
            clear_restore_minimized_source();
            withdraw_notification(BACKGROUND_NOTIFICATION_ID);
            if (held) {
                release();
                held = false;
            }

            quit();
        }
    }
}
