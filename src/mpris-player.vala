namespace MprisMiniPlayer {
    public class MprisPlayer : Object {
        private const string OBJECT_PATH = "/org/mpris/MediaPlayer2";
        private const string PLAYER_IFACE = "org.mpris.MediaPlayer2.Player";
        private const string PROPERTIES_IFACE = "org.freedesktop.DBus.Properties";

        private DBusConnection bus;
        private uint properties_subscription_id;

        public string bus_name { get; construct; }
        public string title { get; private set; default = "Unknown track"; }
        public string artist { get; private set; default = "Unknown artist"; }
        public string album { get; private set; default = ""; }
        public string art_url { get; private set; default = ""; }
        public string playback_status { get; private set; default = "Stopped"; }
        public bool can_go_next { get; private set; default = false; }
        public bool can_go_previous { get; private set; default = false; }
        public bool can_play { get; private set; default = false; }
        public bool can_pause { get; private set; default = false; }

        public signal void changed();

        public MprisPlayer(string bus_name) throws Error {
            Object(bus_name: bus_name);
            bus = Bus.get_sync(BusType.SESSION);
            properties_subscription_id = bus.signal_subscribe(
                bus_name,
                PROPERTIES_IFACE,
                "PropertiesChanged",
                OBJECT_PATH,
                PLAYER_IFACE,
                DBusSignalFlags.NONE,
                on_properties_changed
            );
            refresh();
        }

        ~MprisPlayer() {
            if (properties_subscription_id != 0) {
                bus.signal_unsubscribe(properties_subscription_id);
            }
        }

        public void refresh() {
            try {
                Variant result = bus.call_sync(
                    bus_name,
                    OBJECT_PATH,
                    PROPERTIES_IFACE,
                    "GetAll",
                    new Variant("(s)", PLAYER_IFACE),
                    new VariantType("(a{sv})"),
                    DBusCallFlags.NONE,
                    -1
                );

                Variant properties = result.get_child_value(0);
                update_from_properties(properties);
                changed();
            } catch (Error error) {
                warning("Unable to refresh %s: %s", bus_name, error.message);
            }
        }

        public void previous() {
            call_player_method("Previous");
        }

        public void play_pause() {
            call_player_method("PlayPause");
        }

        public void next() {
            call_player_method("Next");
        }

        public string display_name() {
            return bus_name.substring("org.mpris.MediaPlayer2.".length);
        }

        private void on_properties_changed(
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

            if (changed_interface == PLAYER_IFACE) {
                update_from_properties(changed_properties);
                changed();
            }
        }

        private void update_from_properties(Variant properties) {
            Variant? metadata = lookup_property(properties, "Metadata");
            if (metadata != null) {
                update_metadata(metadata);
            }

            playback_status = get_string_property(properties, "PlaybackStatus", playback_status);
            can_go_next = get_bool_property(properties, "CanGoNext", can_go_next);
            can_go_previous = get_bool_property(properties, "CanGoPrevious", can_go_previous);
            can_play = get_bool_property(properties, "CanPlay", can_play);
            can_pause = get_bool_property(properties, "CanPause", can_pause);
        }

        private void update_metadata(Variant metadata_variant) {
            Variant metadata = unwrap_variant(metadata_variant);
            title = get_metadata_string(metadata, "xesam:title", "Unknown track");
            album = get_metadata_string(metadata, "xesam:album", "");
            art_url = get_metadata_string(metadata, "mpris:artUrl", "");

            Variant? artists_value = lookup_property(metadata, "xesam:artist");
            artist = "Unknown artist";
            if (artists_value != null) {
                string artists = get_string_array_value(artists_value);
                if (artists != "") {
                    artist = artists;
                }
            }
        }

        private Variant? lookup_property(Variant dictionary, string key) {
            VariantIter iter = dictionary.iterator();
            string entry_key;
            Variant entry_value;

            while (iter.next("{sv}", out entry_key, out entry_value)) {
                if (entry_key == key) {
                    return entry_value;
                }
            }

            return null;
        }

        private Variant unwrap_variant(Variant value) {
            if (value.get_type_string() == "v") {
                return value.get_variant();
            }

            return value;
        }

        private string get_string_property(Variant properties, string key, string fallback) {
            Variant? value = lookup_property(properties, key);
            if (value == null) {
                return fallback;
            }

            return unwrap_variant(value).get_string();
        }

        private bool get_bool_property(Variant properties, string key, bool fallback) {
            Variant? value = lookup_property(properties, key);
            if (value == null) {
                return fallback;
            }

            return unwrap_variant(value).get_boolean();
        }

        private string get_metadata_string(Variant metadata, string key, string fallback) {
            Variant? value = lookup_property(metadata, key);
            if (value == null) {
                return fallback;
            }

            return unwrap_variant(value).get_string();
        }

        private string get_string_array_value(Variant value) {
            Variant array = unwrap_variant(value);
            if (array.get_type_string() != "as") {
                return "";
            }

            var builder = new StringBuilder();
            for (size_t i = 0; i < array.n_children(); i++) {
                string item = array.get_child_value(i).get_string();
                if (item == "") {
                    continue;
                }

                if (builder.len > 0) {
                    builder.append(", ");
                }
                builder.append(item);
            }

            return builder.str;
        }

        private void call_player_method(string method_name) {
            try {
                bus.call_sync(
                    bus_name,
                    OBJECT_PATH,
                    PLAYER_IFACE,
                    method_name,
                    null,
                    null,
                    DBusCallFlags.NONE,
                    -1
                );
            } catch (Error error) {
                warning("Unable to call %s on %s: %s", method_name, bus_name, error.message);
            }
        }
    }
}
