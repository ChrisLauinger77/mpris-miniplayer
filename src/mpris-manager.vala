namespace MprisMiniPlayer {
    public class MprisManager : Object {
        private const string MPRIS_PREFIX = "org.mpris.MediaPlayer2.";
        private const string DBUS_NAME = "org.freedesktop.DBus";
        private const string DBUS_PATH = "/org/freedesktop/DBus";
        private DBusConnection? bus;
        private Cancellable lifetime = new Cancellable();
        private uint name_owner_subscription_id;
        private ulong closed_handler_id;
        private uint reconcile_source;
        private uint discovery_retry_source;
        private uint discovery_retry_seconds = 1;
        private bool listing_names = false;
        private bool stopped = false;
        private bool listed_names = false;
        private string manual_selection = "";
        private string[] names = {};
        private HashTable<string, MprisPlayer> players = new HashTable<string, MprisPlayer>(str_hash, str_equal);
        // Only outstanding discovery calls need revisions. Owner events update
        // the registry immediately and invalidate their older lookup replies.
        private HashTable<string, uint> discovering = new HashTable<string, uint>(str_hash, str_equal);
        private string published_players = "";
        private string published_details = "";

        public bool connected { get; private set; default = false; }
        public bool discovery_failed { get; private set; default = false; }
        public bool ready { get; private set; default = false; }
        public MprisPlayer? active_player { get; private set; default = null; }
        public signal void players_changed();
        public signal void players_updated();
        public signal void active_player_changed();
        public signal void discovery_finished();
        public signal void operation_failed(string operation, Error error);

        public MprisManager() {
            start.begin();
        }

        internal MprisManager.with_connection(DBusConnection connection) {
            start.begin(connection);
        }

        private async void start(DBusConnection? connection = null) {
            try {
                bus = connection ?? (yield Bus.get(BusType.SESSION, lifetime));
                if (stopped) return;
                connected = true;
                closed_handler_id = bus.on_closed.connect(() => shutdown());
                name_owner_subscription_id = bus.signal_subscribe(
                    DBUS_NAME, DBUS_NAME, "NameOwnerChanged", DBUS_PATH, null,
                    DBusSignalFlags.NONE, on_name_owner_changed
                );
                yield list_names();
            } catch (Error error) {
                if (!stopped) {
                    listed_names = true;
                    discovery_failed = true;
                    operation_failed("Discover players", error);
                    finish_discovery();
                }
            }
        }

        // Retry the snapshot on the existing connection and subscription. A
        // failed first attempt still releases the startup visibility decision.
        private async void list_names() {
            if (stopped || !connected || listing_names) return;
            listing_names = true;
            bool failed = false;
            try {
                Variant result = yield bus.call(DBUS_NAME, DBUS_PATH, DBUS_NAME, "ListNames",
                    null, new VariantType("(as)"), DBusCallFlags.NONE, 3000, lifetime);
                if (stopped) {
                    listing_names = false;
                    return;
                }
                listed_names = true;
                discovery_failed = false;
                discovery_retry_seconds = 1;
                string[] snapshot_names = result.get_child_value(0).dup_strv();
                foreach (var name in snapshot_names) {
                    if (name.has_prefix(MPRIS_PREFIX)) {
                        // Start independently: one unresponsive player must not
                        // delay discovery of the others.
                        discover.begin(name);
                    }
                }
            } catch (Error error) {
                if (!stopped) {
                    listed_names = true;
                    discovery_failed = true;
                    failed = true;
                    operation_failed("Discover players", error);
                }
            }
            listing_names = false;
            if (stopped) return;
            if (failed) schedule_discovery_retry();
            finish_discovery();
            schedule_reconcile();
        }

        private void schedule_discovery_retry() {
            if (stopped || !connected || discovery_retry_source != 0) return;
            discovery_retry_source = Timeout.add_seconds(discovery_retry_seconds, () => {
                discovery_retry_source = 0;
                list_names.begin();
                return Source.REMOVE;
            });
            discovery_retry_seconds = uint.min(discovery_retry_seconds * 2, 30);
        }

        private async void discover(string name) {
            discovering.insert(name, 1);
            try {
                Variant result = yield bus.call(DBUS_NAME, DBUS_PATH, DBUS_NAME, "GetNameOwner",
                    new Variant("(s)", name), new VariantType("(s)"), DBusCallFlags.NONE, 3000, lifetime);
                if (!stopped && discovering.lookup(name) == 1) {
                    replace_owner(name, result.get_child_value(0).get_string());
                }
            } catch (Error error) {
                if (!stopped && !(error is DBusError.NAME_HAS_NO_OWNER)) {
                    operation_failed("GetNameOwner(%s)".printf(name), error);
                }
            }
            discovering.remove(name);
            if (!stopped && discovering.size() == 0) finish_discovery();
        }

        private void finish_discovery() {
            if (stopped || ready || !listed_names || discovering.size() != 0) return;
            foreach (var player in players.get_values()) if (!player.initialized) return;
            ready = true;
            discovery_finished();
            schedule_reconcile();
        }

        public void shutdown() {
            if (stopped) return;
            stopped = true;
            connected = false;
            lifetime.cancel();
            if (discovery_retry_source != 0) {
                Source.remove(discovery_retry_source);
                discovery_retry_source = 0;
            }
            if (reconcile_source != 0) {
                Source.remove(reconcile_source);
                reconcile_source = 0;
            }
            if (bus != null) {
                if (name_owner_subscription_id != 0) bus.signal_unsubscribe(name_owner_subscription_id);
                if (closed_handler_id != 0) SignalHandler.disconnect(bus, closed_handler_id);
            }
            name_owner_subscription_id = 0;
            closed_handler_id = 0;
            foreach (var player in players.get_values()) player.shutdown();
            players.remove_all();
            names = {};
            active_player = null;
            active_player_changed();
            players_changed();
        }

        public string[] list_players() {
            string[] result = {};
            foreach (var name in names) {
                if (players.contains(name)) result += name;
            }
            return result;
        }

        public MprisPlayer? get_player(string name) {
            return players.lookup(name);
        }

        public void select_player(string name) {
            var player = players.lookup(name);
            if (stopped || player == null || !player.available) return;
            manual_selection = name; // Selecting the current row also pins it.
            switch_active_player(player);
        }

        private void on_name_owner_changed(DBusConnection connection, string? sender,
            string path, string iface, string signal_name, Variant parameters) {
            if (stopped || !parameters.is_of_type(new VariantType("(sss)"))) return;
            string name;
            string old_owner;
            string new_owner;
            parameters.get("(sss)", out name, out old_owner, out new_owner);
            if (!name.has_prefix(MPRIS_PREFIX)) return;
            if (discovering.contains(name)) discovering.replace(name, 2);
            replace_owner(name, new_owner);
        }

        private void replace_owner(string name, string owner) {
            var old = players.lookup(name);
            if (old != null && old.owner == owner) return;
            if (old != null) {
                old.shutdown();
                players.remove(name);
                if (active_player == old) switch_active_player(null);
            }
            if (owner == "") {
                string[] remaining = {};
                foreach (var item in names) if (item != name) remaining += item;
                names = remaining;
                if (manual_selection == name) manual_selection = "";
            } else {
                if (old == null) names += name;
                var player = new MprisPlayer(name, owner, bus);
                players.insert(name, player);
                player.changed.connect(schedule_reconcile);
                player.operation_failed.connect(on_player_operation_failed);
            }
            schedule_reconcile();
        }

        private void on_player_operation_failed(string operation, Error error) {
            operation_failed(operation, error);
        }

        private void schedule_reconcile() {
            if (stopped || reconcile_source != 0) return;
            reconcile_source = Idle.add(() => {
                reconcile_source = 0;
                reconcile();
                return Source.REMOVE;
            });
        }

        private void reconcile() {
            finish_discovery();
            MprisPlayer? best = null;
            int best_priority = -1;
            var signature = new StringBuilder();
            var membership = new StringBuilder();
            foreach (var name in names) {
                var player = players.lookup(name);
                membership.append_printf("%u:%s%u:%s", name.length, name, player.owner.length, player.owner);
                // Length-delimited fields avoid collisions from unusual identities.
                foreach (var field in new string[] { name, player.owner, player.identity,
                    player.desktop_entry, player.playback_status }) {
                    signature.append_printf("%u:%s", field.length, field);
                }
                signature.append(player.available ? "1" : "0");
                if (!player.available) continue;
                int priority = player.playback_status == "Playing" ? 2 : player.playback_status == "Paused" ? 1 : 0;
                if (name == manual_selection) priority = 3;
                if (priority > best_priority) {
                    best = player;
                    best_priority = priority;
                }
            }
            if (best != null) discovery_failed = false;
            // Recovery from an empty snapshot must refresh the error view too.
            signature.append(discovery_failed ? "1" : "0");
            var pinned = players.lookup(manual_selection);
            if (pinned != null && !pinned.available) best = null;
            switch_active_player(best);
            if (published_players != membership.str) {
                published_players = membership.str;
                players_changed();
            }
            if (published_details != signature.str) {
                published_details = signature.str;
                players_updated();
            }
        }

        private void switch_active_player(MprisPlayer? player) {
            if (active_player == player) return;
            if (active_player != null) active_player.set_queue_monitoring(false);
            active_player = player;
            if (active_player != null) active_player.set_queue_monitoring(true);
            active_player_changed();
        }
    }
}
