namespace MprisMiniPlayer {
    public class BackgroundPortal : Object {
        private const string PORTAL_BUS_NAME = "org.freedesktop.portal.Desktop";
        private const string PORTAL_OBJECT_PATH = "/org/freedesktop/portal/desktop";
        private const string BACKGROUND_IFACE = "org.freedesktop.portal.Background";

        private DBusConnection? bus;
        private bool request_sent = false;

        public BackgroundPortal() {
            try {
                bus = Bus.get_sync(BusType.SESSION);
            } catch (Error error) {
                warning("Unable to connect to the session bus for the background portal: %s", error.message);
            }
        }

        public void enter_background(bool autostart) {
            request_background(autostart);
            set_status(_("Monitoring media players"));
        }

        public void leave_background() {
            set_status("");
        }

        private void request_background(bool autostart) {
            if (bus == null || request_sent) {
                return;
            }

            var options = new VariantBuilder(new VariantType("a{sv}"));
            options.add("{sv}", "reason", new Variant.string(_("Keep watching for MPRIS-compatible media players")));
            options.add("{sv}", "autostart", new Variant.boolean(autostart));

            try {
                bus.call_sync(
                    PORTAL_BUS_NAME,
                    PORTAL_OBJECT_PATH,
                    BACKGROUND_IFACE,
                    "RequestBackground",
                    new Variant("(sa{sv})", "", options),
                    new VariantType("(o)"),
                    DBusCallFlags.NONE,
                    -1
                );
                request_sent = true;
            } catch (Error error) {
                debug("Unable to request background portal permission: %s", error.message);
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
