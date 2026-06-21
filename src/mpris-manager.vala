namespace MprisMiniPlayer {
    [DBus (name = "org.freedesktop.DBus")]
    private interface FreedesktopDBus : Object {
        public abstract string[] list_names() throws Error;
    }

    public class MprisManager : Object {
        private const string MPRIS_PREFIX = "org.mpris.MediaPlayer2.";

        private DBusConnection bus;
        private FreedesktopDBus dbus_proxy;
        private uint name_owner_subscription_id;
        private uint player_properties_subscription_id;

        public signal void players_changed();
        public signal void player_priority_changed();

        public MprisManager() throws Error {
            bus = Bus.get_sync(BusType.SESSION);
            dbus_proxy = Bus.get_proxy_sync(
                BusType.SESSION,
                "org.freedesktop.DBus",
                "/org/freedesktop/DBus"
            );
            name_owner_subscription_id = bus.signal_subscribe(
                "org.freedesktop.DBus",
                "org.freedesktop.DBus",
                "NameOwnerChanged",
                "/org/freedesktop/DBus",
                null,
                DBusSignalFlags.NONE,
                on_name_owner_changed
            );
            player_properties_subscription_id = bus.signal_subscribe(
                null,
                "org.freedesktop.DBus.Properties",
                "PropertiesChanged",
                "/org/mpris/MediaPlayer2",
                "org.mpris.MediaPlayer2.Player",
                DBusSignalFlags.NONE,
                on_player_properties_changed
            );
        }

        ~MprisManager() {
            if (name_owner_subscription_id != 0) {
                bus.signal_unsubscribe(name_owner_subscription_id);
            }
            if (player_properties_subscription_id != 0) {
                bus.signal_unsubscribe(player_properties_subscription_id);
            }
        }

        public string[] list_players() {
            try {
                string[] names = dbus_proxy.list_names();
                string[] players = {};
                foreach (var name in names) {
                    if (name.has_prefix(MPRIS_PREFIX)) {
                        players += name;
                    }
                }

                return players;
            } catch (Error error) {
                warning("Unable to list MPRIS players: %s", error.message);
                return {};
            }
        }

        private void on_name_owner_changed(
            DBusConnection connection,
            string? sender_name,
            string object_path,
            string interface_name,
            string signal_name,
            Variant parameters
        ) {
            string name;
            string old_owner;
            string new_owner;
            parameters.get("(sss)", out name, out old_owner, out new_owner);

            if (name.has_prefix(MPRIS_PREFIX)) {
                players_changed();
            }
        }

        private void on_player_properties_changed(
            DBusConnection connection,
            string? sender_name,
            string object_path,
            string interface_name,
            string signal_name,
            Variant parameters
        ) {
            string changed_interface;
            Variant changed_properties;
            Variant invalidated;
            parameters.get("(s@a{sv}@as)", out changed_interface, out changed_properties, out invalidated);

            if (has_property(changed_properties, "PlaybackStatus")) {
                player_priority_changed();
            }
        }

        private bool has_property(Variant dictionary, string key) {
            VariantIter iter = dictionary.iterator();
            string entry_key;
            Variant entry_value;

            while (iter.next("{sv}", out entry_key, out entry_value)) {
                if (entry_key == key) {
                    return true;
                }
            }

            return false;
        }
    }
}
