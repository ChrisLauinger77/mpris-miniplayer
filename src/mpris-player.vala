namespace MprisMiniPlayer {
    public class MprisPlayer : Object {
        private const string OBJECT_PATH = "/org/mpris/MediaPlayer2";
        private const string ROOT_IFACE = "org.mpris.MediaPlayer2";
        private const string PLAYER_IFACE = "org.mpris.MediaPlayer2.Player";
        private const string PROPERTIES_IFACE = "org.freedesktop.DBus.Properties";

        private DBusConnection bus;
        private uint properties_subscription_id;

        public string bus_name { get; construct; }
        public string title { get; private set; default = "Unknown track"; }
        public string artist { get; private set; default = "Unknown artist"; }
        public string album { get; private set; default = ""; }
        public string art_url { get; private set; default = ""; }
        public string identity { get; private set; default = ""; }
        public string desktop_entry { get; private set; default = ""; }
        public string playback_status { get; private set; default = "Stopped"; }
        public string track_id { get; private set; default = ""; }
        public int64 position_us { get; private set; default = 0; }
        public int64 duration_us { get; private set; default = 0; }
        public bool can_go_next { get; private set; default = false; }
        public bool can_go_previous { get; private set; default = false; }
        public bool can_play { get; private set; default = false; }
        public bool can_pause { get; private set; default = false; }
        public bool can_seek { get; private set; default = false; }

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
                Variant root_result = bus.call_sync(
                    bus_name,
                    OBJECT_PATH,
                    PROPERTIES_IFACE,
                    "GetAll",
                    new Variant("(s)", ROOT_IFACE),
                    new VariantType("(a{sv})"),
                    DBusCallFlags.NONE,
                    -1
                );
                update_from_root_properties(root_result.get_child_value(0));

                Variant player_result = bus.call_sync(
                    bus_name,
                    OBJECT_PATH,
                    PROPERTIES_IFACE,
                    "GetAll",
                    new Variant("(s)", PLAYER_IFACE),
                    new VariantType("(a{sv})"),
                    DBusCallFlags.NONE,
                    -1
                );

                Variant properties = player_result.get_child_value(0);
                update_from_properties(properties);
                changed();
            } catch (Error error) {
                warning("Unable to refresh %s: %s", bus_name, error.message);
            }
        }

        public void refresh_position() {
            try {
                Variant result = bus.call_sync(
                    bus_name,
                    OBJECT_PATH,
                    PROPERTIES_IFACE,
                    "Get",
                    new Variant("(ss)", PLAYER_IFACE, "Position"),
                    new VariantType("(v)"),
                    DBusCallFlags.NONE,
                    -1
                );

                position_us = unwrap_variant(result.get_child_value(0)).get_int64();
            } catch (Error error) {
                debug("Unable to refresh position for %s: %s", bus_name, error.message);
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

        public void seek_to_position(int64 position_us) {
            if (!can_seek) {
                return;
            }

            if (position_us < 0) {
                position_us = 0;
            }
            if (duration_us > 0 && position_us > duration_us) {
                position_us = duration_us;
            }

            if (track_id != "") {
                call_player_method_with_parameters(
                    "SetPosition",
                    new Variant("(ox)", track_id, position_us)
                );
                this.position_us = position_us;
                changed();
                return;
            }

            int64 offset_us = position_us - this.position_us;
            call_player_method_with_parameters("Seek", new Variant("(x)", offset_us));
            this.position_us = position_us;
            changed();
        }

        public string display_name() {
            if (identity != "") {
                return identity;
            }

            return bus_name.substring("org.mpris.MediaPlayer2.".length);
        }

        public string icon_name() {
            if (desktop_entry != "") {
                return desktop_entry;
            }

            return "multimedia-player-symbolic";
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

        private void update_from_root_properties(Variant properties) {
            identity = get_string_property(properties, "Identity", identity);
            desktop_entry = get_string_property(properties, "DesktopEntry", desktop_entry);
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
            can_seek = get_bool_property(properties, "CanSeek", can_seek);
            position_us = get_int64_property(properties, "Position", position_us);
        }

        private void update_metadata(Variant metadata_variant) {
            Variant metadata = unwrap_variant(metadata_variant);
            title = get_metadata_string(metadata, "xesam:title", _("Unknown track"));
            album = get_metadata_string(metadata, "xesam:album", "");
            art_url = get_metadata_string(metadata, "mpris:artUrl", "");
            duration_us = get_metadata_int64(metadata, "mpris:length", 0);
            track_id = get_metadata_string(metadata, "mpris:trackid", "");

            Variant? artists_value = lookup_property(metadata, "xesam:artist");
            artist = _("Unknown artist");
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

        private int64 get_int64_property(Variant properties, string key, int64 fallback) {
            Variant? value = lookup_property(properties, key);
            if (value == null) {
                return fallback;
            }

            return unwrap_variant(value).get_int64();
        }

        private string get_metadata_string(Variant metadata, string key, string fallback) {
            Variant? value = lookup_property(metadata, key);
            if (value == null) {
                return fallback;
            }

            return unwrap_variant(value).get_string();
        }

        private int64 get_metadata_int64(Variant metadata, string key, int64 fallback) {
            Variant? value = lookup_property(metadata, key);
            if (value == null) {
                return fallback;
            }

            return unwrap_variant(value).get_int64();
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
            call_player_method_with_parameters(method_name, null);
        }

        private void call_player_method_with_parameters(string method_name, Variant? parameters) {
            try {
                bus.call_sync(
                    bus_name,
                    OBJECT_PATH,
                    PLAYER_IFACE,
                    method_name,
                    parameters,
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
