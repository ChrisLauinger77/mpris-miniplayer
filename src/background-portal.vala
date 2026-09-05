namespace MprisMiniPlayer {
    public class BackgroundPortal : Object {
        private const string PORTAL_BUS_NAME = "org.freedesktop.portal.Desktop";
        private const string PORTAL_OBJECT_PATH = "/org/freedesktop/portal/desktop";
        private const string BACKGROUND_IFACE = "org.freedesktop.portal.Background";
        private const string REQUEST_IFACE = "org.freedesktop.portal.Request";

        private DBusConnection? bus;
        private uint request_subscription_id = 0;
        private uint portal_watch_id = 0;
        private uint generation = 0;
        private string request_path = "";
        private string portal_owner = "";
        private Cancellable lifetime = new Cancellable();
        private Cancellable? request_cancellable;
        private bool stopped = false;
        private bool status_pending = false;
        private bool setting_status = false;
        private string status_message = "";
        private uint request_token_counter = 0;
        private bool request_in_flight = false;
        private bool active_request_force = false;
        private bool request_handled = false;
        private bool request_granted = false;
        private bool requested_autostart = false;
        private bool confirmed_autostart = false;
        private bool pending_request = false;
        private bool pending_request_autostart = false;
        private bool pending_request_force = false;
        private bool in_background = false;

        public signal void autostart_changed(bool enabled, bool portal_answered);

        public BackgroundPortal(bool autostart = false) {
            confirmed_autostart = autostart;
            if (is_flatpak()) initialize.begin();
        }

        internal BackgroundPortal.with_connection(DBusConnection connection) {
            initialize.begin(connection);
        }

        private async void initialize(DBusConnection? connection = null) {
            try {
                bus = connection ?? (yield Bus.get(BusType.SESSION, lifetime));
                if (stopped) return;
                portal_watch_id = Bus.watch_name_on_connection(bus, PORTAL_BUS_NAME, BusNameWatcherFlags.AUTO_START,
                    (connection, name, owner) => {
                        if (stopped) return;
                        portal_owner = owner;
                        run_pending_request();
                        set_status(status_message);
                    },
                    () => {
                        if (request_in_flight && !pending_request) {
                            pending_request = true;
                            pending_request_autostart = requested_autostart;
                            pending_request_force = active_request_force;
                        }
                        cancel_request();
                        portal_owner = "";
                        request_handled = false;
                    });
            } catch (Error error) {
                if (!stopped) debug("Unable to connect to background portal: %s", error.message);
            }
        }

        public void shutdown() {
            if (stopped) return;
            stopped = true;
            cancel_request();
            lifetime.cancel();
            if (portal_watch_id != 0) { Bus.unwatch_name(portal_watch_id); portal_watch_id = 0; }
            pending_request = false;
        }

        private void cancel_request() {
            generation++;
            if (request_in_flight && bus != null && portal_owner != "" && request_path != "") {
                bus.call.begin(portal_owner, request_path, REQUEST_IFACE, "Close", null,
                    new VariantType("()"), DBusCallFlags.NO_AUTO_START, 1000, null, (object, result) => {
                        try { bus.call.end(result); }
                        catch (Error error) { debug("Unable to close background request: %s", error.message); }
                    });
            }
            if (request_cancellable != null) { request_cancellable.cancel(); request_cancellable = null; }
            clear_request_subscription();
            request_in_flight = false;
            request_path = "";
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
            if (stopped || (!is_flatpak() && bus == null)) return;
            if (bus == null || portal_owner == "" || request_in_flight) {
                pending_request = true;
                pending_request_autostart = autostart;
                pending_request_force = pending_request_force || force;
                return;
            }

            bool request_matches_cached_autostart = request_handled && requested_autostart == autostart;
            bool can_reuse_cached_response = !force || (request_granted && confirmed_autostart == autostart);
            if (request_matches_cached_autostart && can_reuse_cached_response) {
                return;
            }

            requested_autostart = autostart;
            active_request_force = force;
            request_in_flight = true;
            request_cancellable = new Cancellable();
            send_request.begin(autostart, ++generation, request_cancellable);
        }

        private async void send_request(bool autostart, uint version, Cancellable cancellable) {
            var options = new VariantBuilder(new VariantType("a{sv}"));
            string handle_token = next_handle_token();
            request_path = build_request_path(handle_token);
            options.add("{sv}", "reason", new Variant.string(_("Keep watching for MPRIS-compatible media players")));
            options.add("{sv}", "autostart", new Variant.boolean(autostart));
            options.add("{sv}", "handle_token", new Variant.string(handle_token));
            options.add("{sv}", "commandline", new Variant.strv({ "mpris-miniplayer" }));
            try {
                subscribe_request_response(request_path);
                Variant result = yield bus.call(portal_owner, PORTAL_OBJECT_PATH, BACKGROUND_IFACE,
                    "RequestBackground", new Variant("(sa{sv})", "", options), new VariantType("(o)"),
                    DBusCallFlags.NO_AUTO_START, 3000, cancellable);
                // Response may arrive before the method reply, or an owner change
                // may already have invalidated this request.
                if (stopped || version != generation || !request_in_flight) return;
                string returned_path = result.get_child_value(0).get_string();
                if (returned_path != request_path) {
                    clear_request_subscription();
                    request_path = returned_path;
                    subscribe_request_response(request_path);
                }
            } catch (Error error) {
                if (stopped || version != generation) return;
                cancel_request();
                debug("Unable to request background portal permission: %s", error.message);
                run_pending_request();
                if (!request_in_flight && !pending_request) autostart_changed(confirmed_autostart, false);
            }
        }

        private void run_pending_request() {
            if (!pending_request || stopped) return;
            bool autostart = pending_request_autostart;
            bool force = pending_request_force;
            pending_request = false;
            pending_request_force = false;
            request_background(autostart, force);
        }

        private void subscribe_request_response(string request_path) {
            request_subscription_id = bus.signal_subscribe(
                portal_owner,
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
            if (stopped || !request_in_flight || sender_name != portal_owner || object_path != request_path
                || !parameters.is_of_type(new VariantType("(ua{sv})"))) return;
            uint response;
            Variant results;
            parameters.get("(u@a{sv})", out response, out results);

            clear_request_subscription();

            request_in_flight = false;
            request_path = "";
            request_cancellable = null;
            request_granted = response == 0 && response_flag(results, "background");
            if (response == 0) confirmed_autostart = response_flag(results, "autostart");
            request_handled = true;

            if (!request_granted) {
                debug("Background portal request was not granted: %u", response);
            } else if (in_background) {
                set_status(_("Monitoring media players"));
            }

            run_pending_request();
            if (!request_in_flight && !pending_request && !stopped) {
                autostart_changed(confirmed_autostart, response == 0);
            }
        }

        internal static bool response_flag(Variant results, string name) {
            if (!results.is_of_type(new VariantType("a{sv}"))) return false;
            Variant? value = results.lookup_value(name, VariantType.BOOLEAN);
            return value != null && value.get_boolean();
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
            status_message = message;
            if (stopped || bus == null || portal_owner == "") return;
            status_pending = true;
            if (!setting_status) send_status.begin();
        }

        private async void send_status() {
            setting_status = true;
            while (status_pending && !stopped && portal_owner != "") {
                status_pending = false;
                var options = new VariantBuilder(new VariantType("a{sv}"));
                if (status_message != "") options.add("{sv}", "message", new Variant.string(status_message));
                try {
                    yield bus.call(portal_owner, PORTAL_OBJECT_PATH, BACKGROUND_IFACE, "SetStatus",
                        new Variant("(a{sv})", options), new VariantType("()"), DBusCallFlags.NO_AUTO_START, 3000, lifetime);
                } catch (Error error) {
                    if (!stopped) debug("Unable to update background portal status: %s", error.message);
                }
            }
            setting_status = false;
        }

        private static bool is_flatpak() {
            return FileUtils.test("/.flatpak-info", FileTest.EXISTS);
        }
    }
}
