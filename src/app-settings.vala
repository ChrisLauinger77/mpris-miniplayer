namespace MprisMiniPlayer {
    public class AppSettings : Object {
        private const string SCHEMA_ID = "io.github.ChrisLauinger.MprisMiniPlayer";
        private const string KEY_SHOW_BACKGROUND_NOTIFICATION = "show-background-notification";
        private const string KEY_START_ON_LOGIN = "start-on-login";
        private const string KEY_AUTOMATIC_WINDOW_VISIBILITY = "automatic-window-visibility";
        private const string KEY_COMPACT_MODE = "compact-mode";

        private GLib.Settings? settings;
        private bool fallback_show_background_notification = true;
        private bool fallback_start_on_login = false;
        private bool fallback_automatic_window_visibility = true;
        private bool fallback_compact_mode = false;
        private bool syncing = false;

        public signal void changed(string key);

        public AppSettings() {
            SettingsSchemaSource? source = SettingsSchemaSource.get_default();
            if (source != null && source.lookup(SCHEMA_ID, true) != null) {
                settings = new GLib.Settings(SCHEMA_ID);
                settings.changed.connect(on_settings_changed);
            } else {
                warning("GSettings schema %s is unavailable; using defaults", SCHEMA_ID);
            }

            sync_start_on_login_from_autostart();
        }

        public bool show_background_notification {
            get {
                if (settings != null) {
                    return settings.get_boolean(KEY_SHOW_BACKGROUND_NOTIFICATION);
                }

                return fallback_show_background_notification;
            }
            set {
                if (settings != null) {
                    settings.set_boolean(KEY_SHOW_BACKGROUND_NOTIFICATION, value);
                } else if (fallback_show_background_notification != value) {
                    fallback_show_background_notification = value;
                    changed(KEY_SHOW_BACKGROUND_NOTIFICATION);
                }
            }
        }

        public bool start_on_login {
            get {
                if (settings != null) {
                    return settings.get_boolean(KEY_START_ON_LOGIN);
                }

                return fallback_start_on_login;
            }
            set {
                apply_start_on_login(value);
            }
        }

        public bool automatic_window_visibility {
            get {
                if (settings != null) {
                    return settings.get_boolean(KEY_AUTOMATIC_WINDOW_VISIBILITY);
                }

                return fallback_automatic_window_visibility;
            }
            set {
                if (settings != null) {
                    settings.set_boolean(KEY_AUTOMATIC_WINDOW_VISIBILITY, value);
                } else if (fallback_automatic_window_visibility != value) {
                    fallback_automatic_window_visibility = value;
                    changed(KEY_AUTOMATIC_WINDOW_VISIBILITY);
                }
            }
        }

        public bool compact_mode {
            get {
                if (settings != null) {
                    return settings.get_boolean(KEY_COMPACT_MODE);
                }

                return fallback_compact_mode;
            }
            set {
                if (settings != null) {
                    settings.set_boolean(KEY_COMPACT_MODE, value);
                } else if (fallback_compact_mode != value) {
                    fallback_compact_mode = value;
                    changed(KEY_COMPACT_MODE);
                }
            }
        }

        public bool has_schema() {
            return settings != null;
        }

        private void on_settings_changed(string key) {
            if (syncing) {
                return;
            }

            if (key == KEY_START_ON_LOGIN) {
                apply_start_on_login(settings.get_boolean(KEY_START_ON_LOGIN));
                return;
            }

            changed(key);
        }

        private void apply_start_on_login(bool enabled) {
            bool success = Autostart.set_enabled(enabled);
            bool actual = Autostart.is_enabled();
            bool final_value = success ? enabled : actual;

            if (!success) {
                warning("Unable to %s start on login", enabled ? "enable" : "disable");
            }

            fallback_start_on_login = final_value;
            if (settings != null && settings.get_boolean(KEY_START_ON_LOGIN) != final_value) {
                syncing = true;
                settings.set_boolean(KEY_START_ON_LOGIN, final_value);
                syncing = false;
            }

            changed(KEY_START_ON_LOGIN);
        }

        private void sync_start_on_login_from_autostart() {
            bool actual = Autostart.is_enabled();
            fallback_start_on_login = actual;

            if (settings != null && settings.get_boolean(KEY_START_ON_LOGIN) != actual) {
                syncing = true;
                settings.set_boolean(KEY_START_ON_LOGIN, actual);
                syncing = false;
            }
        }
    }

    public class Autostart : Object {
        private const string DESKTOP_FILENAME = "io.github.ChrisLauinger.MprisMiniPlayer.desktop";

        public static bool is_enabled() {
            return FileUtils.test(get_autostart_path(), FileTest.EXISTS);
        }

        public static bool set_enabled(bool enabled) {
            try {
                if (enabled) {
                    return write_desktop_file();
                }

                return remove_desktop_file();
            } catch (Error error) {
                warning("Unable to update autostart file: %s", error.message);
                return false;
            }
        }

        private static bool write_desktop_file() throws Error {
            string path = get_autostart_path();
            string contents = """[Desktop Entry]
Type=Application
Name=MPRIS MiniPlayer
Comment=Control MPRIS-compatible media players
Exec=%s
Icon=io.github.ChrisLauinger.MprisMiniPlayer
Terminal=false
Categories=AudioVideo;Audio;Player;GTK;
""".printf(get_exec_command());

            if (FileUtils.test(path, FileTest.EXISTS)) {
                string current_contents;
                FileUtils.get_contents(path, out current_contents);
                if (current_contents == contents) {
                    return true;
                }
            }

            string autostart_dir = get_autostart_dir();
            if (!FileUtils.test(autostart_dir, FileTest.IS_DIR)) {
                File directory = File.new_for_path(autostart_dir);
                directory.make_directory_with_parents();
            }

            FileUtils.set_contents(path, contents);
            return true;
        }

        private static bool remove_desktop_file() throws Error {
            string path = get_autostart_path();
            if (!FileUtils.test(path, FileTest.EXISTS)) {
                return true;
            }

            FileUtils.remove(path);
            return true;
        }

        private static string get_autostart_dir() {
            if (is_flatpak()) {
                return Path.build_filename(Environment.get_home_dir(), ".config", "autostart");
            }

            return Path.build_filename(Environment.get_user_config_dir(), "autostart");
        }

        private static string get_autostart_path() {
            return Path.build_filename(get_autostart_dir(), DESKTOP_FILENAME);
        }

        private static string get_exec_command() {
            if (is_flatpak()) {
                return "flatpak run io.github.ChrisLauinger.MprisMiniPlayer";
            }

            return quote_desktop_exec_arg(Config.EXEC_PATH);
        }

        private static string quote_desktop_exec_arg(string arg) {
            string escaped = arg
                .replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("`", "\\`")
                .replace("$", "\\$");
            return "\"%s\"".printf(escaped);
        }

        private static bool is_flatpak() {
            return FileUtils.test("/.flatpak-info", FileTest.EXISTS);
        }
    }
}
