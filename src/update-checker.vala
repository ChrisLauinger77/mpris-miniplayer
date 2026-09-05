namespace MprisMiniPlayer {
    public class UpdateChecker : Object {
        private const string LATEST_RELEASE_URL =
            "https://github.com/ChrisLauinger77/mpris-miniplayer/releases/latest";
        private const string RELEASE_PATH_PREFIX =
            "/ChrisLauinger77/mpris-miniplayer/releases/tag/";

        private Soup.Session session;
        private Cancellable lifetime = new Cancellable();

        public signal void update_available(string version, string release_url);

        public UpdateChecker() {
            session = new Soup.Session();
            session.timeout = 10;
            session.user_agent = "MPRIS-MiniPlayer/%s".printf(Config.VERSION);
        }

        public void shutdown() {
            lifetime.cancel();
            session.abort();
        }

        public async void check() {
            if (lifetime.is_cancelled()) return;
            var message = new Soup.Message("HEAD", LATEST_RELEASE_URL);

            try {
                yield session.send_and_read_async(message, Priority.DEFAULT, lifetime);
            } catch (Error error) {
                debug("Unable to check for updates: %s", error.message);
                return;
            }

            if (lifetime.is_cancelled()) return;
            if (message.get_status() != Soup.Status.OK) {
                debug("Update check returned HTTP status %u", message.get_status());
                return;
            }

            process_release_uri(message.get_uri());
        }

        internal void process_release_uri(Uri release_uri) {
            string? host = release_uri.get_host();
            string path = release_uri.get_path();
            if (
                release_uri.get_scheme() != "https"
                || host != "github.com"
                || !path.has_prefix(RELEASE_PATH_PREFIX)
            ) {
                warning("Ignoring unexpected update URL: %s", release_uri.to_string());
                return;
            }

            string tag = path.substring(RELEASE_PATH_PREFIX.length);
            if (tag == "" || tag.contains("/")) {
                warning("Ignoring malformed release tag in update URL");
                return;
            }

            string version = tag.has_prefix("v") ? tag.substring(1) : tag;
            if (!is_newer_version(version, Config.VERSION)) {
                return;
            }

            update_available(version, release_uri.to_string());
        }

        public static bool is_newer_version(string candidate, string current) {
            int[] candidate_parts;
            int[] current_parts;
            if (!parse_version(candidate, out candidate_parts)) {
                return false;
            }
            if (!parse_version(current, out current_parts)) {
                return false;
            }

            for (int i = 0; i < candidate_parts.length; i++) {
                if (candidate_parts[i] > current_parts[i]) {
                    return true;
                }
                if (candidate_parts[i] < current_parts[i]) {
                    return false;
                }
            }

            return false;
        }

        private static bool parse_version(string version, out int[] parts) {
            string normalized = version.has_prefix("v") ? version.substring(1) : version;
            string[] fields = normalized.split(".");
            parts = new int[3];
            if (fields.length != 3) {
                parts = {};
                return false;
            }

            for (int i = 0; i < fields.length; i++) {
                string field = fields[i];
                int value = 0;
                if (field == "" || !int.try_parse(field, out value) || value < 0) {
                    parts = {};
                    return false;
                }
                parts[i] = value;
            }

            return true;
        }
    }
}
