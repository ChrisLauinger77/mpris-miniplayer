namespace MprisMiniPlayer {
    [DBus (name = "org.kde.StatusNotifierWatcher")]
    private interface StatusNotifierWatcher : Object {
        public abstract void RegisterStatusNotifierItem(string service) throws DBusError, IOError;
    }

    [DBus (name = "org.kde.StatusNotifierItem")]
    public class StatusNotifierItem : Object {
        private const string APP_ID = "io.github.ChrisLauinger.MprisMiniPlayer";
        private const string MENU_OBJECT_PATH = "/StatusNotifierMenu";

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
                return new ObjectPath(MENU_OBJECT_PATH);
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
        }

        [DBus (name = "SecondaryActivate")]
        public void secondary_activate(int x, int y) throws DBusError, IOError {
            activated();
        }

        [DBus (name = "Scroll")]
        public void scroll(int delta, string orientation) throws DBusError, IOError {
        }
    }

    [DBus (name = "com.canonical.dbusmenu")]
    public class StatusNotifierMenu : Object {
        private const int ROOT_ID = 0;
        private const int SHOW_HIDE_ID = 1;
        private const int COMPACT_MODE_ID = 2;
        private const int PREFERENCES_ID = 3;
        private const int ABOUT_ID = 4;
        private const int QUIT_ID = 5;

        private uint revision = 1;
        private bool window_visible = false;
        private bool compact_mode = false;

        public signal void action_requested(string action);

        [DBus (name = "ItemsPropertiesUpdated")]
        public signal void items_properties_updated(Variant updated_props, Variant removed_props);

        [DBus (name = "LayoutUpdated")]
        public signal void layout_updated(uint revision, int parent);

        [DBus (name = "ItemActivationRequested")]
        public signal void item_activation_requested(int id, uint timestamp);

        [DBus (name = "Version")]
        public uint version {
            get {
                return 3;
            }
        }

        [DBus (name = "TextDirection")]
        public string text_direction {
            owned get {
                return "ltr";
            }
        }

        [DBus (name = "Status")]
        public string status {
            owned get {
                return "normal";
            }
        }

        [DBus (name = "IconThemePath")]
        public string[] icon_theme_path {
            owned get {
                return {};
            }
        }

        [DBus (visible = false)]
        public void set_window_visible(bool visible) {
            if (window_visible == visible) {
                return;
            }

            window_visible = visible;
            revision++;
            layout_updated(revision, ROOT_ID);
        }

        [DBus (visible = false)]
        public void set_compact_mode(bool enabled) {
            if (compact_mode == enabled) {
                return;
            }

            compact_mode = enabled;
            revision++;
            layout_updated(revision, ROOT_ID);
        }

        [DBus (name = "GetLayout")]
        public void get_layout(
            int parent_id,
            int recursion_depth,
            string[] property_names,
            out uint revision,
            [DBus (signature = "(ia{sv}av)")]
            out Variant layout
        ) throws DBusError, IOError {
            revision = this.revision;
            layout = build_layout();
        }

        [DBus (name = "GetGroupProperties", signature = "a(ia{sv})")]
        public Variant get_group_properties(int[] ids, string[] property_names) throws DBusError, IOError {
            var items = new VariantBuilder(new VariantType("a(ia{sv})"));
            int[] requested_ids = ids.length == 0
                ? new int[] { SHOW_HIDE_ID, COMPACT_MODE_ID, PREFERENCES_ID, ABOUT_ID, QUIT_ID }
                : ids;

            foreach (int id in requested_ids) {
                if (id == ROOT_ID || id == SHOW_HIDE_ID || id == COMPACT_MODE_ID || id == PREFERENCES_ID || id == ABOUT_ID || id == QUIT_ID) {
                    items.add_value(new Variant.tuple({
                        new Variant.int32(id),
                        build_properties(id)
                    }));
                }
            }

            return items.end();
        }

        [DBus (name = "GetProperty")]
        public new Variant get_property(int id, string name) throws DBusError, IOError {
            Variant? value = build_properties(id).lookup_value(name, null);
            if (value != null) {
                return value;
            }

            return new Variant.string("");
        }

        [DBus (name = "Event")]
        public void event(int id, string event_id, Variant data, uint timestamp) throws DBusError, IOError {
            if (event_id == "clicked") {
                activate_item(id, timestamp);
            }
        }

        [DBus (name = "AboutToShow")]
        public bool about_to_show(int id) throws DBusError, IOError {
            return false;
        }

        [DBus (name = "AboutToShowGroup")]
        public void about_to_show_group(
            int[] ids,
            out int[] updates_needed,
            out int[] id_errors
        ) throws DBusError, IOError {
            updates_needed = {};
            id_errors = {};
        }

        private Variant build_layout() {
            var children = new VariantBuilder(new VariantType("av"));
            children.add_value(new Variant.variant(build_item(SHOW_HIDE_ID)));
            children.add_value(new Variant.variant(build_item(COMPACT_MODE_ID)));
            children.add_value(new Variant.variant(build_item(PREFERENCES_ID)));
            children.add_value(new Variant.variant(build_item(ABOUT_ID)));
            children.add_value(new Variant.variant(build_item(QUIT_ID)));

            var root_properties = new VariantBuilder(new VariantType("a{sv}"));
            root_properties.add("{sv}", "children-display", new Variant.string("submenu"));

            return new Variant.tuple({
                new Variant.int32(ROOT_ID),
                root_properties.end(),
                children.end()
            });
        }

        private Variant build_item(int id) {
            var children = new VariantBuilder(new VariantType("av"));
            return new Variant.tuple({
                new Variant.int32(id),
                build_properties(id),
                children.end()
            });
        }

        private Variant build_properties(int id) {
            var properties = new VariantBuilder(new VariantType("a{sv}"));
            properties.add("{sv}", "enabled", new Variant.boolean(true));
            properties.add("{sv}", "visible", new Variant.boolean(true));
            properties.add("{sv}", "type", new Variant.string("standard"));
            properties.add("{sv}", "label", new Variant.string(get_label(id)));
            if (id == COMPACT_MODE_ID) {
                properties.add("{sv}", "toggle-type", new Variant.string("checkmark"));
                properties.add("{sv}", "toggle-state", new Variant.int32(compact_mode ? 1 : 0));
            }
            return properties.end();
        }

        private string get_label(int id) {
            switch (id) {
                case SHOW_HIDE_ID:
                    return window_visible ? _("Hide") : _("Show");
                case COMPACT_MODE_ID:
                    return _("Compact Mode");
                case PREFERENCES_ID:
                    return _("Preferences");
                case ABOUT_ID:
                    return _("About");
                case QUIT_ID:
                    return _("Quit");
                default:
                    return "";
            }
        }

        private void activate_item(int id, uint timestamp) {
            switch (id) {
                case SHOW_HIDE_ID:
                    action_requested(window_visible ? "hide" : "show");
                    break;
                case COMPACT_MODE_ID:
                    action_requested("compact-mode");
                    break;
                case PREFERENCES_ID:
                    action_requested("preferences");
                    break;
                case ABOUT_ID:
                    action_requested("about");
                    break;
                case QUIT_ID:
                    action_requested("quit");
                    break;
                default:
                    return;
            }

            item_activation_requested(id, timestamp);
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
        private const string MENU_OBJECT_PATH = "/StatusNotifierMenu";

        private DBusConnection? bus;
        private StatusNotifierItem? item;
        private StatusNotifierMenu? menu;
        private uint item_registration_id = 0;
        private uint menu_registration_id = 0;
        private uint name_owner_subscription_id = 0;
        private bool enabled = false;
        private bool window_visible = false;
        private bool compact_mode = false;

        public bool supported { get; private set; default = false; }

        public signal void support_changed();
        public signal void activated();
        public signal void action_requested(string action);

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

        public void set_window_visible(bool visible) {
            window_visible = visible;

            if (menu != null) {
                menu.set_window_visible(visible);
            }
        }

        public void set_compact_mode(bool enabled) {
            compact_mode = enabled;

            if (menu != null) {
                menu.set_compact_mode(enabled);
            }
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
            menu = new StatusNotifierMenu();
            menu.set_window_visible(window_visible);
            menu.set_compact_mode(compact_mode);
            menu.action_requested.connect((action) => action_requested(action));

            try {
                menu_registration_id = bus.register_object(MENU_OBJECT_PATH, menu);
                item_registration_id = bus.register_object(ITEM_OBJECT_PATH, item);
            } catch (IOError error) {
                warning("Unable to export status indicator: %s", error.message);
                unregister_item();
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
            if (bus != null && menu_registration_id != 0) {
                bus.unregister_object(menu_registration_id);
                menu_registration_id = 0;
            }

            item = null;
            menu = null;
        }

        private static bool is_flatpak() {
            return FileUtils.test("/.flatpak-info", FileTest.EXISTS);
        }
    }
}
