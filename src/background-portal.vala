namespace MprisMiniPlayer {
    public class BackgroundPortal : Object {
        private const string PORTAL_BUS_NAME = "org.freedesktop.portal.Desktop";
        private const string PORTAL_OBJECT_PATH = "/org/freedesktop/portal/desktop";
        private const string BACKGROUND_IFACE = "org.freedesktop.portal.Background";
        private const string REQUEST_IFACE = "org.freedesktop.portal.Request";

        private DBusConnection? bus;
        private uint request_subscription_id = 0;
        private uint request_token_counter = 0;
        private bool request_in_flight = false;
        private bool request_handled = false;
        private bool request_granted = false;
        private bool active_request_autostart = false;
        private bool requested_autostart = false;
        private bool pending_request = false;
        private bool pending_request_autostart = false;
        private bool pending_request_force = false;
        private bool in_background = false;

        public signal void autostart_changed(bool enabled);

        public BackgroundPortal() {
            if (!is_flatpak()) {
                return;
            }

            try {
                bus = Bus.get_sync(BusType.SESSION);
            } catch (Error error) {
                warning("Unable to connect to the session bus for the background portal: %s", error.message);
            }
        }

        public void enter_background(bool autostart) {
            in_background = true;
            request_background(autostart);
            set_status(_("Monitoring media players"));
        }

        public void leave_background() {
            in_background = false;
            if (pending_request && !pending_request_force) {
                pending_request = false;
            }
            if (!pending_request) {
                pending_request_force = false;
            }
            set_status("");
        }

        public void update_autostart(bool autostart) {
            request_background(autostart, true);
        }

        private void request_background(bool autostart, bool force = false) {
            if (bus == null) {
                return;
            }

            if (request_in_flight) {
                pending_request = true;
                pending_request_autostart = autostart;
                pending_request_force = force;
                return;
            }

            if (request_handled && requested_autostart == autostart && (request_granted || !force)) {
                return;
            }

            var options = new VariantBuilder(new VariantType("a{sv}"));
            string handle_token = next_handle_token();
            string request_path = build_request_path(handle_token);
            options.add("{sv}", "reason", new Variant.string(_("Keep watching for MPRIS-compatible media players")));
            options.add("{sv}", "autostart", new Variant.boolean(autostart));
            options.add("{sv}", "handle_token", new Variant.string(handle_token));

            try {
                subscribe_request_response(request_path);
                request_in_flight = true;
                active_request_autostart = autostart;

                Variant result = bus.call_sync(
                    PORTAL_BUS_NAME,
                    PORTAL_OBJECT_PATH,
                    BACKGROUND_IFACE,
                    "RequestBackground",
                    new Variant("(sa{sv})", "", options),
                    new VariantType("(o)"),
                    DBusCallFlags.NONE,
                    -1
                );
                string returned_request_path = result.get_child_value(0).get_string();
                if (returned_request_path != request_path) {
                    debug("Background portal returned request path %s instead of %s", returned_request_path, request_path);
                    clear_request_subscription();
                    subscribe_request_response(returned_request_path);
                }
            } catch (Error error) {
                clear_request_subscription();
                request_in_flight = false;
                debug("Unable to request background portal permission: %s", error.message);
            }
        }

        private void subscribe_request_response(string request_path) {
            request_subscription_id = bus.signal_subscribe(
                PORTAL_BUS_NAME,
                REQUEST_IFACE,
                "Response",
                request_path,
                null,
                DBusSignalFlags.NONE,
                on_request_response
            );
        }

        private void on_request_response(
            DBusConnection connection,
            string? sender_name,
            string object_path,
            string interface_name,
            string signal_name,
            Variant parameters
        ) {
            uint response;
            Variant results;
            parameters.get("(u@a{sv})", out response, out results);

            clear_request_subscription();

            request_in_flight = false;
            request_granted = response == 0;
            requested_autostart = request_granted ? get_response_autostart(results) : false;
            request_handled = true;

            if (!request_granted) {
                debug("Background portal request was not granted: %u", response);
            } else if (in_background) {
                set_status(_("Monitoring media players"));
            }

            bool has_pending_request = pending_request;
            if (!has_pending_request) {
                autostart_changed(requested_autostart);
            }

            if (pending_request) {
                bool autostart = pending_request_autostart;
                bool force = pending_request_force;
                pending_request = false;
                pending_request_force = false;
                request_background(autostart, force);
            }
        }

        private bool get_response_autostart(Variant results) {
            Variant? autostart = results.lookup_value("autostart", VariantType.BOOLEAN);
            if (autostart == null) {
                return active_request_autostart;
            }

            return autostart.get_boolean();
        }

        private string next_handle_token() {
            request_token_counter++;
            return "mpris_miniplayer_%u".printf(request_token_counter);
        }

        private string build_request_path(string handle_token) {
            string sender = bus.get_unique_name();
            if (sender.has_prefix(":")) {
                sender = sender.substring(1);
            }

            sender = sender.replace(".", "_");
            return "%s/request/%s/%s".printf(PORTAL_OBJECT_PATH, sender, handle_token);
        }

        private void clear_request_subscription() {
            if (bus != null && request_subscription_id != 0) {
                bus.signal_unsubscribe(request_subscription_id);
                request_subscription_id = 0;
            }
        }

        private void set_status(string message) {
            if (bus == null) {
                return;
            }

            var options = new VariantBuilder(new VariantType("a{sv}"));
            if (message != "") {
                options.add("{sv}", "message", new Variant.string(message));
            }

            try {
                bus.call_sync(
                    PORTAL_BUS_NAME,
                    PORTAL_OBJECT_PATH,
                    BACKGROUND_IFACE,
                    "SetStatus",
                    new Variant("(a{sv})", options),
                    null,
                    DBusCallFlags.NONE,
                    -1
                );
            } catch (Error error) {
                debug("Unable to update background portal status: %s", error.message);
            }
        }

        private static bool is_flatpak() {
            return FileUtils.test("/.flatpak-info", FileTest.EXISTS);
        }
    }
}
