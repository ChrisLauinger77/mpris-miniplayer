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
        private bool in_background = false;

        public BackgroundPortal() {
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
            set_status("");
        }

        private void request_background(bool autostart) {
            if (bus == null || request_in_flight || request_handled) {
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
            request_handled = true;
            request_granted = response == 0;

            if (!request_granted) {
                debug("Background portal request was not granted: %u", response);
            } else if (in_background) {
                set_status(_("Monitoring media players"));
            }
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
    }
}
