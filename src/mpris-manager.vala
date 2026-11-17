namespace MprisMiniPlayer {
    public class MprisApplication : Object {
        public string id { get; construct; }
        public string display_name { get; construct; }
        public string icon_name { get; construct; }
        public bool running { get; construct; }

        internal MprisApplication(string id, string display_name, string icon_name, bool running) {
            Object(id: id, display_name: display_name, icon_name: icon_name, running: running);
        }
    }

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
        // Ownership is tracked even for ignored applications, which have no
        // player model, transport subscriptions, or metadata requests.
        private HashTable<string, string> owners = new HashTable<string, string>(str_hash, str_equal);
        private HashTable<string, bool> blacklisted = new HashTable<string, bool>(str_hash, str_equal);
        private HashTable<string, string> application_names = new HashTable<string, string>(str_hash, str_equal);
        private HashTable<string, string> application_icons = new HashTable<string, string>(str_hash, str_equal);
        private HashTable<string, MprisPlayer> players = new HashTable<string, MprisPlayer>(str_hash, str_equal);
        // Only outstanding discovery calls need revisions. Owner events update
        // the registry immediately and invalidate their older lookup replies.
        private HashTable<string, uint> discovering = new HashTable<string, uint>(str_hash, str_equal);
        private string published_players = "";
        private string published_details = "";
        private string published_applications = "";

        public bool connected { get; private set; default = false; }
        public bool discovery_failed { get; private set; default = false; }
        public bool ready { get; private set; default = false; }
        public MprisPlayer? active_player { get; private set; default = null; }
        public signal void players_changed();
        public signal void players_updated();
        public signal void applications_changed();
        public signal void active_player_changed();
        public signal void discovery_finished();
        public signal void operation_failed(string operation, Error error);

        public MprisManager(string[] blacklisted_players = {}) {
            set_blacklisted_players(blacklisted_players);
            start.begin();
        }

        internal MprisManager.with_connection(DBusConnection connection, string[] blacklisted_players = {}) {
            set_blacklisted_players(blacklisted_players);
            start.begin(connection);
        }

        internal static string application_id(string name) {
            string suffix = name.has_prefix(MPRIS_PREFIX) ? name.substring(MPRIS_PREFIX.length) : name;
            int dot = suffix.last_index_of_char('.');
            if (dot <= 0) return suffix;
            string instance = suffix.substring(dot + 1);
            // Dots can belong to the application ID itself (io.bassi.Amberol).
            // Strip only the conventional trailing .instance<PID> component;
            // ambiguous or unfamiliar suffixes remain part of the identifier.
            const string INSTANCE_PREFIX = "instance";
            if (!instance.has_prefix(INSTANCE_PREFIX) || instance.length == INSTANCE_PREFIX.length) return suffix;
            for (int i = INSTANCE_PREFIX.length; i < instance.length; i++) {
                if (!instance[i].isdigit()) return suffix;
            }
            return suffix.substring(0, dot);
        }

        public bool is_blacklisted(string id) {
            return blacklisted.contains(id);
        }

        public void set_blacklisted_players(string[] ids) {
            if (stopped) return;
            blacklisted.remove_all();
            foreach (var id in ids) if (id != "") blacklisted.insert(id, true);
            if (is_blacklisted(application_id(manual_selection))) manual_selection = "";
            foreach (var name in names) {
                var player = players.lookup(name);
                if (is_blacklisted(application_id(name))) {
                    if (player != null) {
                        remember_application(player);
                        player.shutdown();
                        players.remove(name);
                    }
                } else if (player == null) {
                    add_player(name, owners.lookup(name));
                }
            }
            // Rebind controls synchronously so an ignored active model cannot
            // receive another command before the next idle reconciliation.
            reconcile();
        }

        public MprisApplication[] list_applications() {
            var running = new HashTable<string, bool>(str_hash, str_equal);
            var ids = new HashTable<string, bool>(str_hash, str_equal);
            foreach (var name in names) {
                string id = application_id(name);
                running.insert(id, true);
                ids.insert(id, true);
            }
            foreach (var id in blacklisted.get_keys()) ids.insert(id, true);
            var sorted = ids.get_keys();
            sorted.sort(strcmp);
            MprisApplication[] result = {};
            foreach (var id in sorted) {
                result += new MprisApplication(id, application_names.lookup(id) ?? id,
                    application_icons.lookup(id) ?? "multimedia-player-symbolic", running.contains(id));
            }
            return result;
        }

        private void remember_application(MprisPlayer player) {
            string id = application_id(player.bus_name);
            if (player.identity != "") application_names.replace(id, player.identity);
            if (player.desktop_entry != "") application_icons.replace(id, player.icon_name());
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
            if (stopped || discovering.contains(name)) return;
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
            owners.remove_all();
            application_names.remove_all();
            application_icons.remove_all();
            names = {};
            active_player = null;
            active_player_changed();
            players_changed();
            applications_changed();
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
            if (owners.lookup(name) == owner) return;
            var old = players.lookup(name);
            if (old != null) {
                remember_application(old);
                old.shutdown();
                players.remove(name);
                if (active_player == old) switch_active_player(null);
            }
            if (owner == "") {
                owners.remove(name);
                string[] remaining = {};
                foreach (var item in names) if (item != name) remaining += item;
                names = remaining;
                if (manual_selection == name) manual_selection = "";
            } else {
                if (!owners.contains(name)) names += name;
                owners.replace(name, owner);
                if (!is_blacklisted(application_id(name))) add_player(name, owner);
            }
            schedule_reconcile();
        }

        private void add_player(string name, string owner) {
            var player = new MprisPlayer(name, owner, bus);
            players.insert(name, player);
            player.changed.connect(schedule_reconcile);
            player.operation_failed.connect(on_player_operation_failed);
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
            if (stopped) return;
            finish_discovery();
            if (stopped) return;
            MprisPlayer? best = null;
            int best_priority = -1;
            var signature = new StringBuilder();
            var membership = new StringBuilder();
            foreach (var name in names) {
                var player = players.lookup(name);
                if (player == null) continue;
                remember_application(player);
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
            if (stopped) return;
            if (published_players != membership.str) {
                published_players = membership.str;
                players_changed();
            }
            if (published_details != signature.str) {
                published_details = signature.str;
                players_updated();
            }
            var applications = new StringBuilder();
            foreach (var app in list_applications()) {
                foreach (var field in new string[] { app.id, app.display_name, app.icon_name }) {
                    applications.append_printf("%u:%s", field.length, field);
                }
                applications.append(app.running ? "1" : "0");
                applications.append(is_blacklisted(app.id) ? "1" : "0");
            }
            if (published_applications != applications.str) {
                published_applications = applications.str;
                applications_changed();
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
