namespace MprisMiniPlayer {
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
        private ulong seeked_handler_id;
        private Cancellable lifetime = new Cancellable();
        private Cancellable? queue_request;
        private bool stopped = false;
        private bool refreshing = false;
        private bool refresh_pending = false;
        private bool queue_loading = false;
        private bool queue_pending = false;
        private bool position_loading = false;
        private bool position_pending = false;
        private VariantDict? root_updates;
        private VariantDict? player_updates;
        private HashTable<string, bool> root_invalidated = new HashTable<string, bool>(str_hash, str_equal);
        private HashTable<string, bool> player_invalidated = new HashTable<string, bool>(str_hash, str_equal);
        private uint position_revision = 0;
        private uint retry_source = 0;
        private uint retry_seconds = 1;
        private int64 position_anchor = 0;
        private int64 position_time = 0;
        private double rate = 1.0;
        private bool seek_pending = false;
        private bool seeking = false;
        private int64 requested_position;
        private string requested_track = "";
        private uint64 requested_track_revision;
        private HashTable<string, Variant> pending_writes = new HashTable<string, Variant>(str_hash, str_equal);
        private HashTable<string, Variant> writing = new HashTable<string, Variant>(str_hash, str_equal);
        private HashTable<string, uint> property_versions = new HashTable<string, uint>(str_hash, str_equal);
        private bool monitor_track_list = true;
        private double restore_volume = 1.0;
        private uint queue_refresh_generation = 0;

        public string bus_name { get; construct; }
        public string owner { get; construct; default = ""; }
        public bool initialized { get; private set; default = false; }
        public bool available { get; private set; default = false; }
        public bool can_play_pause {
            get { return available && can_control && (playback_status == "Playing" ? can_pause : can_play); }
        }
        public string title { get; private set; default = "Unknown track"; }
        public string artist { get; private set; default = "Unknown artist"; }
        public string album { get; private set; default = ""; }
        public string art_url { get; private set; default = ""; }
        public string identity { get; private set; default = ""; }
        public string desktop_entry { get; private set; default = ""; }
        public string playback_status { get; private set; default = "Stopped"; }
        public string track_id { get; private set; default = ""; }
        public uint64 track_revision { get; private set; default = 0; }
        public int64 position_us {
            get {
                double value = position_anchor;
                if (available && playback_status == "Playing") {
                    value += (get_monotonic_time() - position_time) * rate;
                }
                if (duration_us > 0) value = double.min(value, duration_us);
                return value >= int64.MAX ? int64.MAX : (int64) double.max(0, value);
            }
        }
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
        public signal void operation_failed(string operation, Error error);

        public MprisPlayer(string bus_name, string owner, DBusConnection bus) {
            Object(bus_name: bus_name, owner: owner);
            monitor_track_list = false;
            transport = new DBusMprisTransport(bus, owner);
            connect_transport();
            refresh();
        }

        public MprisPlayer.with_transport(string bus_name, MprisTransport transport) {
            Object(bus_name: bus_name, owner: "");
            this.transport = transport;
            connect_transport();
            refresh();
        }

        ~MprisPlayer() {
            shutdown();
        }

        // The registry stops a model before removing it. Pending callbacks may
        // still own it, but cancellation and stopped prevent further publication.
        public void shutdown() {
            if (stopped) return;
            stopped = true;
            available = false;
            can_control = false;
            lifetime.cancel();
            if (queue_request != null) queue_request.cancel();
            if (retry_source != 0) {
                Source.remove(retry_source);
                retry_source = 0;
            }
            if (SignalHandler.is_connected(transport, properties_changed_handler_id)) SignalHandler.disconnect(transport, properties_changed_handler_id);
            if (SignalHandler.is_connected(transport, track_list_changed_handler_id)) SignalHandler.disconnect(transport, track_list_changed_handler_id);
            if (SignalHandler.is_connected(transport, seeked_handler_id)) SignalHandler.disconnect(transport, seeked_handler_id);
            transport.shutdown();
            pending_writes.remove_all();
            queue = {};
            queue_revision++;
        }

        private void connect_transport() {
            properties_changed_handler_id = transport.properties_changed.connect(on_transport_properties_changed);
            track_list_changed_handler_id = transport.track_list_changed.connect(() => refresh_queue());
            seeked_handler_id = transport.seeked.connect((position) => {
                if (stopped) return;
                set_position(position);
                changed();
            });
        }

        public void set_queue_monitoring(bool enabled) {
            if (monitor_track_list == enabled || stopped) return;
            monitor_track_list = enabled;
            refresh_queue();
        }

        public void refresh() {
            if (stopped) return;
            refresh_pending = true;
            if (!refreshing) refresh_async.begin();
        }

        private async void refresh_async() {
            refreshing = true;
            while (refresh_pending && !stopped) {
                refresh_pending = false;
                player_updates = new VariantDict();
                player_invalidated.remove_all();
                uint position_version = position_revision;
                bool failed = false;
                try {
                    Variant properties = yield transport.get_all(PLAYER_IFACE, lifetime);
                    if (stopped) break;
                    if (!properties.is_of_type(new VariantType("a{sv}"))) {
                        throw new IOError.INVALID_DATA("Invalid MPRIS player properties");
                    }
                    properties = merge_snapshot(properties, player_updates, player_invalidated);
                    player_updates = null;
                    update_from_properties(properties, true, position_version == position_revision);
                    available = true;
                    changed();
                } catch (Error error) {
                    if (stopped) break;
                    failed = true;
                    available = false;
                    can_control = false;
                    changed();
                    report_error("GetAll(Player)", error);
                }
                player_updates = null;
                root_updates = new VariantDict();
                root_invalidated.remove_all();
                try {
                    Variant properties = yield transport.get_all(ROOT_IFACE, lifetime);
                    if (stopped) break;
                    if (!properties.is_of_type(new VariantType("a{sv}"))) {
                        throw new IOError.INVALID_DATA("Invalid MPRIS root properties");
                    }
                    properties = merge_snapshot(properties, root_updates, root_invalidated);
                    root_updates = null;
                    bool had_track_list = has_track_list;
                    update_from_root_properties(properties, true);
                    if (had_track_list != has_track_list || queue_revision == 0) refresh_queue();
                    changed();
                } catch (Error error) {
                    if (stopped) break;
                    failed = true;
                    // Root support is independent of the usable Player interface.
                    report_error("GetAll(Root)", error);
                }
                root_updates = null;
                initialized = true;
                changed();
                if (failed) {
                    schedule_retry();
                    break;
                }
                retry_seconds = 1;
                if (retry_source != 0) {
                    Source.remove(retry_source);
                    retry_source = 0;
                }
            }
            refreshing = false;
        }

        private void schedule_retry() {
            if (stopped || retry_source != 0) return;
            retry_source = Timeout.add_seconds(retry_seconds, () => {
                retry_source = 0;
                refresh();
                return Source.REMOVE;
            });
            retry_seconds = uint.min(retry_seconds * 2, 30);
        }

        private void set_position(int64 value) {
            position_anchor = int64.max(0, value);
            position_time = get_monotonic_time();
            position_revision++;
        }

        public void refresh_position() {
            if (stopped) return;
            position_pending = true;
            if (!position_loading) sample_position.begin();
        }

        private async void sample_position() {
            position_loading = true;
            while (position_pending && !stopped) {
                position_pending = false;
                uint version = position_revision;
                try {
                    Variant value = yield transport.read_property_async(PLAYER_IFACE, "Position", lifetime);
                    if (!stopped && version == position_revision && value.is_of_type(VariantType.INT64)) {
                        set_position(value.get_int64());
                        changed();
                    }
                } catch (Error error) {
                    if (!stopped) report_error("Get(Position)", error);
                }
            }
            position_loading = false;
        }

        public void previous() {
            if (available && can_control && can_go_previous) run_command.begin(PLAYER_IFACE, "Previous", null);
        }

        public void play_pause() {
            if (can_play_pause) run_command.begin(PLAYER_IFACE, playback_status == "Playing" ? "Pause" : "Play", null);
        }

        public void next() {
            if (available && can_control && can_go_next) run_command.begin(PLAYER_IFACE, "Next", null);
        }

        public void toggle_shuffle() {
            if (available && has_shuffle && can_control) {
                Variant? requested = requested_value("Shuffle");
                set_player_property("Shuffle", new Variant.boolean(!(requested != null ? requested.get_boolean() : shuffle)));
            }
        }

        public void cycle_loop_status() {
            Variant? requested = requested_value("LoopStatus");
            change_loop_status(next_loop_status(requested != null ? requested.get_string() : loop_status));
        }

        public void change_loop_status(string status) {
            if (available && has_loop_status && can_control && is_loop_status(status)) {
                set_player_property("LoopStatus", new Variant.string(status));
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
            if (!has_track_list || !is_track_id(requested_track_id)) {
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

            if (!available || !can_control || stopped) return false;
            run_command.begin(TRACKLIST_IFACE, "GoTo", new Variant("(o)", requested_track_id));
            return true; // Accepted; remote failures are reported via operation_failed.
        }

        public void refresh_queue(bool emit_changed = true) {
            queue_refresh_generation++;
            if (queue_request != null) queue_request.cancel();
            queue_pending = !stopped && monitor_track_list && has_track_list;
            if (!queue_pending) {
                if (queue.length > 0) {
                    queue = {};
                    queue_revision++;
                    if (!stopped && emit_changed) changed();
                }
                return;
            }
            if (!queue_loading) refresh_queue_async.begin();
        }

        private async void refresh_queue_async() {
            queue_loading = true;
            while (queue_pending && !stopped) {
                queue_pending = false;
                uint generation = queue_refresh_generation;
                queue_request = new Cancellable();
                try {
                    Variant tracks = unwrap_variant(
                        yield transport.read_property_async(TRACKLIST_IFACE, "Tracks", queue_request)
                    );
                    if (!tracks.is_of_type(new VariantType("ao"))) {
                        throw new IOError.INVALID_DATA("MPRIS Tracks is not an object-path array");
                    }
                    if (stopped || generation != queue_refresh_generation || !has_track_list) {
                        continue;
                    }

                    string[] track_ids = {};
                    var seen = new HashTable<string, bool>(str_hash, str_equal);
                    for (size_t index = 0; index < tracks.n_children(); index++) {
                        string id = tracks.get_child_value(index).get_string();
                        if (is_track_id(id) && !seen.contains(id)) {
                            track_ids += id;
                            seen.insert(id, true);
                        }
                    }

                    MprisTrack[] loaded_queue = yield load_track_metadata(
                        track_ids,
                        generation
                    );
                    if (stopped || generation != queue_refresh_generation || !has_track_list) {
                        continue;
                    }
                    queue = loaded_queue;
                    queue_revision++;
                    changed();
                } catch (Error error) {
                    if (stopped || generation != queue_refresh_generation) {
                        continue;
                    }
                    report_error("Refresh queue", error);
                    queue = {};
                    queue_revision++;
                    changed();
                }
            }
            queue_request = null;
            queue_loading = false;
        }

        public void seek_to_position(int64 position_us) {
            if (!available || !can_control || !can_seek || stopped) return;
            requested_position = int64.max(0, position_us);
            if (duration_us > 0) requested_position = int64.min(requested_position, duration_us);
            requested_track = track_id;
            requested_track_revision = track_revision;
            seek_pending = true;
            if (!seeking) seek_async.begin();
        }

        private async void seek_async() {
            seeking = true;
            while (seek_pending && !stopped && available && can_control && can_seek) {
                seek_pending = false;
                string target_track = requested_track;
                uint64 target_revision = requested_track_revision;
                int64 target = requested_position;
                if (target_revision != track_revision) continue;
                // Invalidate a Position read started before this seek.
                position_revision++;
                try {
                    if (target_track != "") {
                        yield transport.call_async(PLAYER_IFACE, "SetPosition",
                            new Variant("(ox)", target_track, target), new VariantType("()"), lifetime);
                    } else {
                        yield transport.call_async(PLAYER_IFACE, "Seek",
                            new Variant("(x)", target - position_us), new VariantType("()"), lifetime);
                    }
                } catch (Error error) {
                    if (!stopped) report_error("Seek", error);
                }
                // SetPosition may legally be ignored. Read the actual position.
                if (!stopped && target_revision == track_revision) refresh_position();
            }
            seeking = false;
        }

        public void set_player_volume(double volume) {
            if (!available || !has_volume || !can_control || !volume.is_finite()) return;
            set_player_property("Volume", new Variant.double(double.max(0.0, volume)));
        }

        public void toggle_mute() {
            if (!has_volume || !can_control) {
                return;
            }

            double target = requested_volume();
            if (target > 0.0) {
                restore_volume = target;
                set_player_volume(0.0);
            } else {
                set_player_volume(restore_volume > 0.0 ? restore_volume : 1.0);
            }
        }

        public void adjust_volume(double delta) {
            if (!has_volume || !can_control) {
                return;
            }

            double target = requested_volume();
            if (delta > 0.0 && target >= 1.0) {
                return;
            }

            double adjusted_volume = double.max(0.0, target + delta);
            if (delta > 0.0) {
                adjusted_volume = double.min(1.0, adjusted_volume);
            }
            set_player_volume(adjusted_volume);
        }

        public string display_name() {
            if (identity != "") {
                return identity;
            }

            const string prefix = "org.mpris.MediaPlayer2.";
            return bus_name.has_prefix(prefix) ? bus_name.substring(prefix.length) : bus_name;
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
            if (stopped || !changed_properties.is_of_type(new VariantType("a{sv}"))) return;
            if (changed_interface == PLAYER_IFACE) {
                foreach (var name in new string[] { "Volume", "Shuffle", "LoopStatus" }) {
                    if (lookup_property(changed_properties, name) != null || invalidates(invalidated, name)) {
                        property_versions.replace(name, property_versions.lookup(name) + 1);
                    }
                }
                if (player_updates != null) record_updates(player_updates, changed_properties, invalidated, player_invalidated);
                update_from_properties(changed_properties);
                changed();
            } else if (changed_interface == ROOT_IFACE) {
                if (root_updates != null) record_updates(root_updates, changed_properties, invalidated, root_invalidated);
                bool had_track_list = has_track_list;
                update_from_root_properties(changed_properties);
                if (had_track_list != has_track_list) refresh_queue();
                changed();
            } else if (changed_interface == TRACKLIST_IFACE) {
                refresh_queue();
            }
            if ((changed_interface == PLAYER_IFACE || changed_interface == ROOT_IFACE)
                && invalidated.is_of_type(VariantType.STRING_ARRAY) && invalidated.n_children() > 0) {
                refresh();
            }
        }

        private bool invalidates(Variant values, string name) {
            if (!values.is_of_type(VariantType.STRING_ARRAY)) return false;
            foreach (var value in values.dup_strv()) if (value == name) return true;
            return false;
        }

        private void record_updates(VariantDict updates, Variant properties, Variant invalidated, HashTable<string, bool> removed) {
            VariantIter iter = properties.iterator();
            string key;
            Variant value;
            while (iter.next("{sv}", out key, out value)) updates.insert_value(key, value);
            if (invalidated.is_of_type(VariantType.STRING_ARRAY)) {
                foreach (var name in invalidated.dup_strv()) {
                    updates.remove(name);
                    removed.insert(name, true);
                }
            }
        }

        private Variant merge_snapshot(Variant snapshot, VariantDict updates, HashTable<string, bool> invalidated) {
            var result = new VariantDict(snapshot);
            foreach (var name in invalidated.get_keys()) result.remove(name);
            VariantIter iter = updates.end().iterator();
            string key;
            Variant value;
            while (iter.next("{sv}", out key, out value)) result.insert_value(key, value);
            return result.end();
        }

        private void update_from_root_properties(Variant properties, bool snapshot = false) {
            if (snapshot) {
                identity = "";
                desktop_entry = "";
                has_track_list = false;
            }
            identity = get_string_property(properties, "Identity", identity);
            desktop_entry = get_string_property(properties, "DesktopEntry", desktop_entry);
            has_track_list = get_bool_property(properties, "HasTrackList", has_track_list);
            if (!has_track_list && queue.length > 0) {
                queue = {};
                queue_revision++;
            }
        }

        private void update_from_properties(Variant properties, bool snapshot = false, bool accept_position = true) {
            string previous_status = playback_status;
            string previous_track = track_id;
            string previous_title = title;
            string previous_artist = artist;
            string previous_album = album;
            double previous_rate = rate;
            int64 current_position = position_us;
            if (snapshot) {
                playback_status = "Stopped";
                can_go_next = can_go_previous = can_play = can_pause = can_seek = can_control = false;
                has_shuffle = shuffle = has_loop_status = has_volume = false;
                loop_status = "None";
                volume = 1.0;
                rate = 1.0;
                update_metadata(new VariantBuilder(new VariantType("a{sv}")).end());
            }
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
            Variant? rate_value = lookup_typed_property(properties, "Rate", VariantType.DOUBLE);
            if (rate_value != null && rate_value.get_double().is_finite() && rate_value.get_double() != 0) {
                rate = rate_value.get_double();
            }
            if (playback_status != "Playing" && playback_status != "Paused") playback_status = "Stopped";
            bool track_changed = previous_track != track_id || (track_id == ""
                && (title != previous_title || artist != previous_artist || album != previous_album));
            if (track_changed) {
                track_revision++;
                seek_pending = false;
                set_position(0);
            } else if (previous_status != playback_status || previous_rate != rate) {
                set_position(current_position);
            }
            Variant? position_value = lookup_typed_property(properties, "Position", VariantType.INT64);
            if (position_value != null && accept_position) {
                set_position(position_value.get_int64());
            } else if (track_changed || previous_status != playback_status || previous_rate != rate) {
                refresh_position();
            }

            if (lookup_property(properties, "Shuffle") != null) { has_shuffle = false; shuffle = false; }
            if (lookup_property(properties, "LoopStatus") != null) { has_loop_status = false; loop_status = "None"; }
            if (lookup_property(properties, "Volume") != null) { has_volume = false; volume = 1.0; }
            Variant? shuffle_value = lookup_typed_property(properties, "Shuffle", VariantType.BOOLEAN);
            if (shuffle_value != null) {
                has_shuffle = true;
                shuffle = unwrap_variant(shuffle_value).get_boolean();
            }

            Variant? loop_status_value = lookup_typed_property(properties, "LoopStatus", VariantType.STRING);
            if (loop_status_value != null) {
                string status = unwrap_variant(loop_status_value).get_string();
                has_loop_status = true;
                loop_status = is_loop_status(status) ? status : "None";
            }

            Variant? volume_value = lookup_typed_property(properties, "Volume", VariantType.DOUBLE);
            if (volume_value != null) {
                double reported_volume = volume_value.get_double();
                has_volume = reported_volume.is_finite();
                volume = has_volume ? double.max(0.0, reported_volume) : 1.0;
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
            duration_us = int64.max(0, get_metadata_int64(metadata, "mpris:length", 0));
            track_id = get_metadata_track_id(metadata);

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
            if (!dictionary.is_of_type(new VariantType("a{sv}"))) {
                return null;
            }
            return dictionary.lookup_value(key, null);
        }

        private Variant? lookup_typed_property(Variant dictionary, string key, VariantType type) {
            Variant? value = lookup_property(dictionary, key);
            if (value == null) {
                return null;
            }
            value = unwrap_variant(value);
            return value.is_of_type(type) ? value : null;
        }

        private static bool is_track_id(string id) {
            return Variant.is_object_path(id)
                && id != "/org/mpris/MediaPlayer2/TrackList/NoTrack";
        }

        private string get_metadata_track_id(Variant metadata) {
            Variant? value = lookup_property(metadata, "mpris:trackid");
            if (value == null) {
                return "";
            }
            value = unwrap_variant(value);
            // Tolerate players using a string, but never construct an invalid 'o'.
            if (!value.is_of_type(VariantType.OBJECT_PATH) && !value.is_of_type(VariantType.STRING)) {
                return "";
            }
            string id = value.get_string();
            return is_track_id(id) ? id : "";
        }

        private Variant unwrap_variant(Variant value) {
            if (value.get_type_string() == "v") {
                return value.get_variant();
            }

            return value;
        }

        private string get_string_property(Variant properties, string key, string fallback) {
            Variant? value = lookup_typed_property(properties, key, VariantType.STRING);
            if (value == null) {
                return fallback;
            }

            return unwrap_variant(value).get_string();
        }

        private bool get_bool_property(Variant properties, string key, bool fallback) {
            Variant? value = lookup_typed_property(properties, key, VariantType.BOOLEAN);
            if (value == null) {
                return fallback;
            }

            return unwrap_variant(value).get_boolean();
        }

        private string get_metadata_string(Variant metadata, string key, string fallback) {
            Variant? value = lookup_typed_property(metadata, key, VariantType.STRING);
            if (value == null) {
                return fallback;
            }

            return unwrap_variant(value).get_string();
        }

        private int64 get_metadata_int64(Variant metadata, string key, int64 fallback) {
            Variant? value = lookup_typed_property(metadata, key, VariantType.INT64);
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
                    new VariantType("(aa{sv})"), queue_request
                );
                if (generation != queue_refresh_generation) {
                    return {};
                }
                if (!result.is_of_type(new VariantType("(aa{sv})"))) {
                    throw new IOError.INVALID_DATA("MPRIS track metadata has an invalid type");
                }
                Variant metadata_list = result.get_child_value(0);
                if (metadata_list.n_children() > batch_size) {
                    throw new IOError.INVALID_DATA("MPRIS returned more metadata entries than requested");
                }
                var metadata_by_id = new HashTable<string, Variant>(str_hash, str_equal);
                for (size_t index = 0; index < metadata_list.n_children(); index++) {
                    Variant metadata = metadata_list.get_child_value(index);
                    string id = get_metadata_track_id(metadata);
                    if (id != "") {
                        metadata_by_id.insert(id, metadata);
                    }
                }

                for (int index = 0; index < batch_size; index++) {
                    string title = _("Unknown track");
                    string artist = _("Unknown artist");
                    string album = "";
                    Variant? metadata = metadata_by_id.lookup(batch_ids[index]);
                    if (metadata != null) {
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

        private Variant? requested_value(string name) {
            return pending_writes.lookup(name) ?? writing.lookup(name);
        }

        private double requested_volume() {
            Variant? value = requested_value("Volume");
            return value != null ? value.get_double() : volume;
        }

        // At most one write per property is in flight. Slider bursts retain only
        // the latest requested value; state comes from signals or a fresh snapshot.
        private void set_player_property(string name, Variant value) {
            if (stopped) return;
            pending_writes.replace(name, value);
            if (!writing.contains(name)) write_player_property.begin(name);
        }

        private async void write_player_property(string name) {
            while (!stopped && available && can_control && pending_writes.contains(name)) {
                if ((name == "Volume" && !has_volume) || (name == "Shuffle" && !has_shuffle)
                    || (name == "LoopStatus" && !has_loop_status)) break;
                Variant value = pending_writes.lookup(name);
                pending_writes.remove(name);
                writing.replace(name, value);
                try {
                    yield transport.write_property(PLAYER_IFACE, name, value, lifetime);
                    if (stopped) break;
                    if (pending_writes.contains(name)) continue;
                    uint version = property_versions.lookup(name);
                    Variant actual = yield transport.read_property_async(PLAYER_IFACE, name, lifetime);
                    if (stopped) break;
                    if (!pending_writes.contains(name) && version == property_versions.lookup(name)) {
                        var properties = new VariantBuilder(new VariantType("a{sv}"));
                        properties.add("{sv}", name, actual);
                        update_from_properties(properties.end());
                        changed();
                    }
                } catch (Error error) {
                    if (!stopped) {
                        report_error("Set/Get(%s)".printf(name), error);
                        refresh();
                    }
                }
            }
            pending_writes.remove(name);
            writing.remove(name);
        }

        private static bool is_loop_status(string status) {
            return status == "None" || status == "Track" || status == "Playlist";
        }

        private async void run_command(string iface, string method, Variant? parameters) {
            if (stopped) return;
            try {
                yield transport.call_async(iface, method, parameters, new VariantType("()"), lifetime);
            } catch (Error error) {
                if (!stopped) report_error(method, error);
            }
            if (!stopped) {
                refresh();
                if (iface == TRACKLIST_IFACE) refresh_queue();
            }
        }

        private void report_error(string operation, Error error) {
            if (error is IOError.CANCELLED) return;
            debug("%s on %s (%s): %s", operation, bus_name, owner, error.message);
            operation_failed("%s: %s".printf(display_name(), operation), error);
        }
    }
}
