namespace MprisMiniPlayer {
    public class MprisManager : Object {
        private const string MPRIS_PREFIX = "org.mpris.MediaPlayer2.";

        private DBusConnection bus;
        private uint name_owner_subscription_id;

        public signal void players_changed();

        public MprisManager() throws Error {
            bus = Bus.get_sync(BusType.SESSION);
            name_owner_subscription_id = bus.signal_subscribe(
                "org.freedesktop.DBus",
                "org.freedesktop.DBus",
                "NameOwnerChanged",
                "/org/freedesktop/DBus",
                null,
                DBusSignalFlags.NONE,
                on_name_owner_changed
            );
        }

        ~MprisManager() {
            if (name_owner_subscription_id != 0) {
                bus.signal_unsubscribe(name_owner_subscription_id);
            }
        }

        public string[] list_players() {
            try {
                Variant result = bus.call_sync(
                    "org.freedesktop.DBus",
                    "/org/freedesktop/DBus",
                    "org.freedesktop.DBus",
                    "ListNames",
                    null,
                    new VariantType("(as)"),
                    DBusCallFlags.NONE,
                    -1
                );

                string[] names;
                result.get("(^as)", out names);

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
    }
}
