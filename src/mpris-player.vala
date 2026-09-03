namespace MprisMiniPlayer {
    public interface MprisTransport : Object {
        public signal void properties_changed(
            string interface_name,
            Variant changed_properties,
            Variant invalidated_properties
        );
        public signal void track_list_changed();

        public abstract Variant get_all(string interface_name) throws Error;
        public abstract Variant read_property(string interface_name, string property_name) throws Error;
        public abstract async Variant read_property_async(
            string interface_name,
            string property_name
        ) throws Error;
        public abstract void write_property(
            string interface_name,
            string property_name,
            Variant value
        ) throws Error;
        public abstract Variant call(
            string interface_name,
            string method_name,
            Variant? parameters,
            VariantType? reply_type = null
        ) throws Error;
        public abstract async Variant call_async(
            string interface_name,
            string method_name,
            Variant? parameters,
            VariantType? reply_type = null
        ) throws Error;
    }

    private class DBusMprisTransport : Object, MprisTransport {
        private const string OBJECT_PATH = "/org/mpris/MediaPlayer2";
        private const string TRACKLIST_IFACE = "org.mpris.MediaPlayer2.TrackList";
        private const string PROPERTIES_IFACE = "org.freedesktop.DBus.Properties";

        private DBusConnection bus;
        private string bus_name;
        private uint properties_subscription_id;
        private uint track_list_subscription_id;

        public DBusMprisTransport(string bus_name, bool monitor_track_list) throws Error {
            this.bus_name = bus_name;
            bus = Bus.get_sync(BusType.SESSION);
            properties_subscription_id = bus.signal_subscribe(
                bus_name,
                PROPERTIES_IFACE,
                "PropertiesChanged",
                OBJECT_PATH,
                null,
                DBusSignalFlags.NONE,
                on_properties_changed
            );
            if (monitor_track_list) {
                track_list_subscription_id = bus.signal_subscribe(
                    bus_name,
                    TRACKLIST_IFACE,
                    null,
                    OBJECT_PATH,
                    null,
                    DBusSignalFlags.NONE,
                    on_track_list_signal
                );
            }
        }

        ~DBusMprisTransport() {
            if (properties_subscription_id != 0) {
                bus.signal_unsubscribe(properties_subscription_id);
            }
            if (track_list_subscription_id != 0) {
                bus.signal_unsubscribe(track_list_subscription_id);
            }
        }

        public Variant get_all(string interface_name) throws Error {
            Variant result = bus.call_sync(
                bus_name,
                OBJECT_PATH,
                PROPERTIES_IFACE,
                "GetAll",
                new Variant("(s)", interface_name),
                new VariantType("(a{sv})"),
                DBusCallFlags.NONE,
                -1
            );
            return result.get_child_value(0);
        }

        public Variant read_property(string interface_name, string property_name) throws Error {
            Variant result = bus.call_sync(
                bus_name,
                OBJECT_PATH,
                PROPERTIES_IFACE,
                "Get",
                new Variant("(ss)", interface_name, property_name),
                new VariantType("(v)"),
                DBusCallFlags.NONE,
                -1
            );
            return result.get_child_value(0);
        }

        public async Variant read_property_async(
            string interface_name,
            string property_name
        ) throws Error {
            Variant result = yield bus.call(
                bus_name,
                OBJECT_PATH,
                PROPERTIES_IFACE,
                "Get",
                new Variant("(ss)", interface_name, property_name),
                new VariantType("(v)"),
                DBusCallFlags.NONE,
                -1,
                null
            );
            return result.get_child_value(0);
        }

        public void write_property(
            string interface_name,
            string property_name,
            Variant value
        ) throws Error {
            bus.call_sync(
                bus_name,
                OBJECT_PATH,
                PROPERTIES_IFACE,
                "Set",
                new Variant("(ssv)", interface_name, property_name, value),
                null,
                DBusCallFlags.NONE,
                -1
            );
        }

        public Variant call(
            string interface_name,
            string method_name,
            Variant? parameters,
            VariantType? reply_type = null
        ) throws Error {
            return bus.call_sync(
                bus_name,
                OBJECT_PATH,
                interface_name,
                method_name,
                parameters,
                reply_type,
                DBusCallFlags.NONE,
                -1
            );
        }

        public async Variant call_async(
            string interface_name,
            string method_name,
            Variant? parameters,
            VariantType? reply_type = null
        ) throws Error {
            return yield bus.call(
                bus_name,
                OBJECT_PATH,
                interface_name,
                method_name,
                parameters,
                reply_type,
                DBusCallFlags.NONE,
                -1,
                null
            );
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
            Variant changed;
            Variant invalidated;
            parameters.get("(s@a{sv}@as)", out changed_interface, out changed, out invalidated);
            properties_changed(changed_interface, changed, invalidated);
        }

        private void on_track_list_signal(
            DBusConnection connection,
            string? sender_name,
            string object_path,
            string interface_name,
            string signal_name,
            Variant parameters
        ) {
            switch (signal_name) {
                case "TrackListReplaced":
                case "TrackAdded":
                case "TrackRemoved":
                case "TrackMetadataChanged":
                    track_list_changed();
                    break;
            }
        }
    }

    public class MprisTrack : Object {
        public string id { get; construct; }
        public string title { get; construct; }
        public string artist { get; construct; }
        public string album { get; construct; }

        public MprisTrack(string id, string title, string artist, string album) {
            Object(id: id, title: title, artist: artist, album: album);
        }
    }

    public class MprisPlayer : Object {
        private const int TRACK_METADATA_BATCH_SIZE = 64;
        private const string ROOT_IFACE = "org.mpris.MediaPlayer2";
        private const string PLAYER_IFACE = "org.mpris.MediaPlayer2.Player";
        private const string TRACKLIST_IFACE = "org.mpris.MediaPlayer2.TrackList";

        private MprisTransport transport;
        private ulong properties_changed_handler_id;
        private ulong track_list_changed_handler_id;
        private bool monitor_track_list = true;
        private double restore_volume = 1.0;
        private uint queue_refresh_generation = 0;

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
        public double volume { get; private set; default = 1.0; }
        public bool can_go_next { get; private set; default = false; }
        public bool can_go_previous { get; private set; default = false; }
        public bool can_play { get; private set; default = false; }
        public bool can_pause { get; private set; default = false; }
        public bool can_seek { get; private set; default = false; }
        public bool can_control { get; private set; default = false; }
        public bool has_volume { get; private set; default = false; }
        public bool has_shuffle { get; private set; default = false; }
        public bool shuffle { get; private set; default = false; }
        public bool has_loop_status { get; private set; default = false; }
        public string loop_status { get; private set; default = "None"; }
        public bool has_track_list { get; private set; default = false; }
        public MprisTrack[] queue = {};
        public uint64 queue_revision { get; private set; default = 0; }

        public signal void changed();

        public MprisPlayer(string bus_name, bool monitor_track_list = true) throws Error {
            Object(bus_name: bus_name);
            this.monitor_track_list = monitor_track_list;
            transport = new DBusMprisTransport(bus_name, monitor_track_list);
            connect_transport();
            refresh();
        }

        public MprisPlayer.with_transport(string bus_name, MprisTransport transport) {
            Object(bus_name: bus_name);
            this.transport = transport;
            connect_transport();
            refresh();
        }

        ~MprisPlayer() {
            if (
                properties_changed_handler_id != 0
                && SignalHandler.is_connected(transport, properties_changed_handler_id)
            ) {
                SignalHandler.disconnect(transport, properties_changed_handler_id);
            }
            if (
                track_list_changed_handler_id != 0
                && SignalHandler.is_connected(transport, track_list_changed_handler_id)
            ) {
                SignalHandler.disconnect(transport, track_list_changed_handler_id);
            }
        }

        private void connect_transport() {
            properties_changed_handler_id = transport.properties_changed.connect(
                on_transport_properties_changed
            );
            if (monitor_track_list) {
                track_list_changed_handler_id = transport.track_list_changed.connect(
                    () => refresh_queue()
                );
            }
        }

        public void refresh() {
            try {
                has_track_list = false;
                update_from_root_properties(transport.get_all(ROOT_IFACE));
                has_shuffle = false;
                shuffle = false;
                has_loop_status = false;
                loop_status = "None";
                update_from_properties(transport.get_all(PLAYER_IFACE));
                if (monitor_track_list) {
                    refresh_queue(false);
                }
                changed();
            } catch (Error error) {
                warning("Unable to refresh %s: %s", bus_name, error.message);
            }
        }

        public void refresh_position() {
            try {
                position_us = unwrap_variant(
                    transport.read_property(PLAYER_IFACE, "Position")
                ).get_int64();
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

        public void toggle_shuffle() {
            if (!has_shuffle || !can_control) {
                return;
            }

            bool enabled = !shuffle;
            if (set_player_property("Shuffle", new Variant.boolean(enabled))) {
                shuffle = enabled;
                changed();
            }
        }

        public void cycle_loop_status() {
            change_loop_status(next_loop_status(loop_status));
        }

        public void change_loop_status(string status) {
            if (!has_loop_status || !can_control || !is_loop_status(status)) {
                return;
            }

            if (set_player_property("LoopStatus", new Variant.string(status))) {
                loop_status = status;
                changed();
            }
        }

        public static string next_loop_status(string status) {
            switch (status) {
                case "None":
                    return "Track";
                case "Track":
                    return "Playlist";
                default:
                    return "None";
            }
        }

        public bool go_to(string requested_track_id) {
            if (!has_track_list || requested_track_id == "") {
                return false;
            }

            bool found = false;
            foreach (var track in queue) {
                if (track.id == requested_track_id) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                refresh_queue();
                return false;
            }

            try {
                transport.call(
                    TRACKLIST_IFACE,
                    "GoTo",
                    new Variant("(o)", requested_track_id)
                );
                return true;
            } catch (Error error) {
                warning("Unable to select queue track on %s: %s", bus_name, error.message);
                refresh_queue();
                return false;
            }
        }

        public void refresh_queue(bool emit_changed = true) {
            uint generation = ++queue_refresh_generation;
            if (!has_track_list) {
                if (queue.length > 0) {
                    queue = {};
                    queue_revision++;
                    if (emit_changed) {
                        changed();
                    }
                }
                return;
            }

            refresh_queue_async.begin(generation);
        }

        private async void refresh_queue_async(uint generation) {
            try {
                Variant tracks = unwrap_variant(
                    yield transport.read_property_async(TRACKLIST_IFACE, "Tracks")
                );
                if (generation != queue_refresh_generation || !has_track_list) {
                    return;
                }

                int track_count = (int) tracks.n_children();
                string[] track_ids = new string[track_count];
                for (int index = 0; index < track_count; index++) {
                    track_ids[index] = tracks.get_child_value(index).get_string();
                }

                MprisTrack[] loaded_queue = yield load_track_metadata(
                    track_ids,
                    generation
                );
                if (generation != queue_refresh_generation || !has_track_list) {
                    return;
                }
                queue = loaded_queue;
                queue_revision++;
                changed();
            } catch (Error error) {
                if (generation != queue_refresh_generation) {
                    return;
                }
                debug("Unable to refresh queue for %s: %s", bus_name, error.message);
                queue = {};
                queue_revision++;
                changed();
            }
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
                if (!call_player_method_with_parameters(
                    "SetPosition",
                    new Variant("(ox)", track_id, position_us)
                )) {
                    refresh_position();
                    return;
                }
                this.position_us = position_us;
                changed();
                return;
            }

            int64 offset_us = position_us - this.position_us;
            if (!call_player_method_with_parameters("Seek", new Variant("(x)", offset_us))) {
                refresh_position();
                return;
            }
            this.position_us = position_us;
            changed();
        }

        public void set_player_volume(double volume) {
            if (!has_volume || !can_control) {
                return;
            }

            try {
                transport.write_property(PLAYER_IFACE, "Volume", new Variant.double(volume));
                this.volume = volume;
                if (volume > 0.0) {
                    restore_volume = volume;
                }
                changed();
            } catch (Error error) {
                warning("Unable to set volume on %s: %s", bus_name, error.message);
                refresh();
            }
        }

        public void toggle_mute() {
            if (!has_volume || !can_control) {
                return;
            }

            if (volume > 0.0) {
                restore_volume = volume;
                set_player_volume(0.0);
            } else {
                set_player_volume(restore_volume > 0.0 ? restore_volume : 1.0);
            }
        }

        public void adjust_volume(double delta) {
            if (!has_volume || !can_control) {
                return;
            }

            if (delta > 0.0 && volume >= 1.0) {
                return;
            }

            double adjusted_volume = double.max(0.0, volume + delta);
            if (delta > 0.0) {
                adjusted_volume = double.min(1.0, adjusted_volume);
            }
            set_player_volume(adjusted_volume);
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

        private void on_transport_properties_changed(
            string changed_interface,
            Variant changed_properties,
            Variant invalidated
        ) {
            if (
                (changed_interface == PLAYER_IFACE && (
                    string_array_contains(invalidated, "Shuffle")
                    || string_array_contains(invalidated, "LoopStatus")
                ))
                || (changed_interface == ROOT_IFACE
                    && string_array_contains(invalidated, "HasTrackList"))
            ) {
                refresh();
                return;
            }

            if (changed_interface == PLAYER_IFACE) {
                update_from_properties(changed_properties);
                changed();
            } else if (changed_interface == ROOT_IFACE) {
                bool previously_had_track_list = has_track_list;
                update_from_root_properties(changed_properties);
                if (monitor_track_list && has_track_list != previously_had_track_list) {
                    refresh_queue(false);
                }
                changed();
            } else if (changed_interface == TRACKLIST_IFACE) {
                refresh_queue();
            }
        }

        private void update_from_root_properties(Variant properties) {
            identity = get_string_property(properties, "Identity", identity);
            desktop_entry = get_string_property(properties, "DesktopEntry", desktop_entry);
            has_track_list = get_bool_property(properties, "HasTrackList", has_track_list);
            if (!has_track_list && queue.length > 0) {
                queue = {};
                queue_revision++;
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
            can_seek = get_bool_property(properties, "CanSeek", can_seek);
            can_control = get_bool_property(properties, "CanControl", can_control);
            position_us = get_int64_property(properties, "Position", position_us);

            Variant? shuffle_value = lookup_property(properties, "Shuffle");
            if (shuffle_value != null) {
                has_shuffle = true;
                shuffle = unwrap_variant(shuffle_value).get_boolean();
            }

            Variant? loop_status_value = lookup_property(properties, "LoopStatus");
            if (loop_status_value != null) {
                string status = unwrap_variant(loop_status_value).get_string();
                has_loop_status = true;
                loop_status = is_loop_status(status) ? status : "None";
            }

            Variant? volume_value = lookup_property(properties, "Volume");
            if (volume_value != null) {
                has_volume = true;
                volume = unwrap_variant(volume_value).get_double();
                if (volume > 0.0) {
                    restore_volume = volume;
                }
            }
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

        private bool string_array_contains(Variant array, string needle) {
            VariantIter iter = array.iterator();
            string value;
            while (iter.next("s", out value)) {
                if (value == needle) {
                    return true;
                }
            }
            return false;
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

        private async MprisTrack[] load_track_metadata(
            string[] track_ids,
            uint generation
        ) throws Error {
            MprisTrack[] loaded_tracks = new MprisTrack[track_ids.length];
            if (track_ids.length == 0) {
                return loaded_tracks;
            }

            for (int offset = 0; offset < track_ids.length; offset += TRACK_METADATA_BATCH_SIZE) {
                int batch_size = int.min(
                    TRACK_METADATA_BATCH_SIZE,
                    track_ids.length - offset
                );
                string[] batch_ids = new string[batch_size];
                for (int index = 0; index < batch_size; index++) {
                    batch_ids[index] = track_ids[offset + index];
                }

                Variant result = yield transport.call_async(
                    TRACKLIST_IFACE,
                    "GetTracksMetadata",
                    new Variant("(@ao)", new Variant.objv(batch_ids)),
                    new VariantType("(aa{sv})")
                );
                if (generation != queue_refresh_generation) {
                    return {};
                }
                Variant metadata_list = result.get_child_value(0);

                for (int index = 0; index < batch_size; index++) {
                    string title = _("Unknown track");
                    string artist = _("Unknown artist");
                    string album = "";
                    if (index < metadata_list.n_children()) {
                        Variant metadata = metadata_list.get_child_value(index);
                        title = get_metadata_string(metadata, "xesam:title", title);
                        album = get_metadata_string(metadata, "xesam:album", "");
                        Variant? artists_value = lookup_property(metadata, "xesam:artist");
                        if (artists_value != null) {
                            string artists = get_string_array_value(artists_value);
                            if (artists != "") {
                                artist = artists;
                            }
                        }
                    }
                    loaded_tracks[offset + index] = new MprisTrack(
                        track_ids[offset + index],
                        title,
                        artist,
                        album
                    );
                }
            }

            return loaded_tracks;
        }

        private bool set_player_property(string name, Variant value) {
            try {
                transport.write_property(PLAYER_IFACE, name, value);
                return true;
            } catch (Error error) {
                warning("Unable to set %s on %s: %s", name, bus_name, error.message);
                refresh();
                return false;
            }
        }

        private static bool is_loop_status(string status) {
            return status == "None" || status == "Track" || status == "Playlist";
        }

        private void call_player_method(string method_name) {
            call_player_method_with_parameters(method_name, null);
        }

        private bool call_player_method_with_parameters(string method_name, Variant? parameters) {
            try {
                transport.call(
                    PLAYER_IFACE,
                    method_name,
                    parameters
                );
                return true;
            } catch (Error error) {
                warning("Unable to call %s on %s: %s", method_name, bus_name, error.message);
                return false;
            }
        }
    }
}
