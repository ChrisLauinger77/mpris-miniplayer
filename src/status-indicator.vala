namespace MprisMiniPlayer {
    [DBus (name = "org.kde.StatusNotifierWatcher")]
    private interface StatusNotifierWatcher : Object {
        public abstract void RegisterStatusNotifierItem(string service) throws DBusError, IOError;
    }

    [DBus (name = "org.kde.StatusNotifierItem")]
    public class StatusNotifierItem : Object {
        private const string APP_ID = "io.github.ChrisLauinger.MprisMiniPlayer";

        public signal void activated();

        [DBus (name = "NewIcon")]
        public signal void new_icon();

        [DBus (name = "NewTitle")]
        public signal void new_title();

        [DBus (name = "Category")]
        public string category {
            owned get {
                return "ApplicationStatus";
            }
        }

        [DBus (name = "Id")]
        public string id {
            owned get {
                return APP_ID;
            }
        }

        [DBus (name = "Title")]
        public string title {
            owned get {
                return _("MPRIS MiniPlayer");
            }
        }

        [DBus (name = "Status")]
        public string status {
            owned get {
                return "Active";
            }
        }

        [DBus (name = "IconName")]
        public string icon_name {
            owned get {
                return APP_ID;
            }
        }

        [DBus (name = "ItemIsMenu")]
        public bool item_is_menu {
            get {
                return false;
            }
        }

        [DBus (name = "Menu")]
        public ObjectPath menu {
            owned get {
                return new ObjectPath("/");
            }
        }

        [DBus (name = "WindowId")]
        public uint32 window_id {
            get {
                return 0;
            }
        }

        [DBus (name = "OverlayIconName")]
        public string overlay_icon_name {
            owned get {
                return "";
            }
        }

        [DBus (name = "AttentionIconName")]
        public string attention_icon_name {
            owned get {
                return "";
            }
        }

        [DBus (name = "AttentionMovieName")]
        public string attention_movie_name {
            owned get {
                return "";
            }
        }

        [DBus (name = "Activate")]
        public void activate(int x, int y) throws DBusError, IOError {
            activated();
        }

        [DBus (name = "ContextMenu")]
        public void context_menu(int x, int y) throws DBusError, IOError {
            activated();
        }

        [DBus (name = "SecondaryActivate")]
        public void secondary_activate(int x, int y) throws DBusError, IOError {
            activated();
        }

        [DBus (name = "Scroll")]
        public void scroll(int delta, string orientation) throws DBusError, IOError {
        }
    }

    public class StatusIndicator : Object {
        private const string WATCHER_BUS_NAME = "org.kde.StatusNotifierWatcher";
        private const string WATCHER_OBJECT_PATH = "/StatusNotifierWatcher";
        private const string WATCHER_IFACE = "org.kde.StatusNotifierWatcher";
        private const string DBUS_BUS_NAME = "org.freedesktop.DBus";
        private const string DBUS_OBJECT_PATH = "/org/freedesktop/DBus";
        private const string DBUS_IFACE = "org.freedesktop.DBus";
        private const string ITEM_OBJECT_PATH = "/StatusNotifierItem";

        private DBusConnection? bus;
        private StatusNotifierItem? item;
        private uint item_registration_id = 0;
        private uint name_owner_subscription_id = 0;
        private bool enabled = false;

        public bool supported { get; private set; default = false; }

        public signal void support_changed();
        public signal void activated();

        public StatusIndicator() {
            if (is_flatpak()) {
                return;
            }

            try {
                bus = Bus.get_sync(BusType.SESSION);
            } catch (Error error) {
                warning("Unable to connect to the session bus for the status indicator: %s", error.message);
                return;
            }

            subscribe_name_owner_changes();
            refresh_supported();
        }

        public void set_enabled(bool enabled) {
            this.enabled = enabled;
            update_registration();
        }

        public void shutdown() {
            if (bus != null && name_owner_subscription_id != 0) {
                bus.signal_unsubscribe(name_owner_subscription_id);
                name_owner_subscription_id = 0;
            }

            unregister_item();
        }

        private void subscribe_name_owner_changes() {
            name_owner_subscription_id = bus.signal_subscribe(
                DBUS_BUS_NAME,
                DBUS_IFACE,
                "NameOwnerChanged",
                DBUS_OBJECT_PATH,
                WATCHER_BUS_NAME,
                DBusSignalFlags.NONE,
                on_name_owner_changed
            );
        }

        private void on_name_owner_changed(
            DBusConnection connection,
            string? sender_name,
            string object_path,
            string interface_name,
            string signal_name,
            Variant parameters
        ) {
            refresh_supported();
        }

        private void refresh_supported() {
            bool old_supported = supported;
            supported = name_has_owner(WATCHER_BUS_NAME);

            if (old_supported != supported) {
                support_changed();
            }

            update_registration();
        }

        private bool name_has_owner(string name) {
            if (bus == null) {
                return false;
            }

            try {
                Variant result = bus.call_sync(
                    DBUS_BUS_NAME,
                    DBUS_OBJECT_PATH,
                    DBUS_IFACE,
                    "NameHasOwner",
                    new Variant("(s)", name),
                    new VariantType("(b)"),
                    DBusCallFlags.NONE,
                    -1
                );
                return result.get_child_value(0).get_boolean();
            } catch (Error error) {
                debug("Unable to check status indicator support: %s", error.message);
                return false;
            }
        }

        private void update_registration() {
            if (!enabled || !supported || bus == null) {
                unregister_item();
                return;
            }

            register_item();
        }

        private void register_item() {
            if (item_registration_id != 0) {
                register_with_watcher();
                return;
            }

            item = new StatusNotifierItem();
            item.activated.connect(() => activated());

            try {
                item_registration_id = bus.register_object(ITEM_OBJECT_PATH, item);
            } catch (IOError error) {
                warning("Unable to export status indicator: %s", error.message);
                item = null;
                item_registration_id = 0;
                return;
            }

            register_with_watcher();
        }

        private void register_with_watcher() {
            try {
                bus.call_sync(
                    WATCHER_BUS_NAME,
                    WATCHER_OBJECT_PATH,
                    WATCHER_IFACE,
                    "RegisterStatusNotifierItem",
                    new Variant("(s)", bus.get_unique_name()),
                    null,
                    DBusCallFlags.NONE,
                    -1
                );
            } catch (Error error) {
                debug("Unable to register status indicator with watcher: %s", error.message);
            }
        }

        private void unregister_item() {
            if (bus != null && item_registration_id != 0) {
                bus.unregister_object(item_registration_id);
                item_registration_id = 0;
            }

            item = null;
        }

        private static bool is_flatpak() {
            return FileUtils.test("/.flatpak-info", FileTest.EXISTS);
        }
    }
}
