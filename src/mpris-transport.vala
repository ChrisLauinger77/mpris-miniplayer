namespace MprisMiniPlayer {
    public interface MprisTransport : Object {
        public signal void properties_changed(string interface_name, Variant changed, Variant invalidated);
        public signal void track_list_changed();
        public signal void seeked(int64 position_us);

        public abstract async Variant get_all(string interface_name, Cancellable? cancellable = null) throws Error;
        public abstract async Variant read_property_async(
            string interface_name, string property_name, Cancellable? cancellable = null
        ) throws Error;
        public abstract async void write_property(
            string interface_name, string property_name, Variant value, Cancellable? cancellable = null
        ) throws Error;
        public abstract async Variant call_async(
            string interface_name, string method_name, Variant? parameters,
            VariantType? reply_type = null, Cancellable? cancellable = null
        ) throws Error;
        public abstract void shutdown();
    }

    // One transport belongs to one unique bus owner, never to its replacement.
    internal class DBusMprisTransport : Object, MprisTransport {
        private const string OBJECT_PATH = "/org/mpris/MediaPlayer2";
        private const string PLAYER_IFACE = "org.mpris.MediaPlayer2.Player";
        private const string TRACKLIST_IFACE = "org.mpris.MediaPlayer2.TrackList";
        private const string PROPERTIES_IFACE = "org.freedesktop.DBus.Properties";
        private const int CALL_TIMEOUT_MS = 3000;

        private DBusConnection bus;
        private string owner;
        private Cancellable lifetime = new Cancellable();
        private uint properties_subscription_id;
        private uint track_list_subscription_id;
        private uint seeked_subscription_id;

        public DBusMprisTransport(DBusConnection bus, string owner) {
            this.bus = bus;
            this.owner = owner;
            properties_subscription_id = bus.signal_subscribe(
                owner, PROPERTIES_IFACE, "PropertiesChanged", OBJECT_PATH, null,
                DBusSignalFlags.NONE, on_properties_changed
            );
            track_list_subscription_id = bus.signal_subscribe(
                owner, TRACKLIST_IFACE, null, OBJECT_PATH, null,
                DBusSignalFlags.NONE, on_track_list_signal
            );
            seeked_subscription_id = bus.signal_subscribe(
                owner, PLAYER_IFACE, "Seeked", OBJECT_PATH, null,
                DBusSignalFlags.NONE, on_seeked
            );
        }

        // signal_subscribe owns its callback target: the owner must stop us
        // explicitly before dropping its reference, rather than relying on finalize.
        public void shutdown() {
            lifetime.cancel();
            if (properties_subscription_id != 0) {
                bus.signal_unsubscribe(properties_subscription_id);
                properties_subscription_id = 0;
            }
            if (track_list_subscription_id != 0) {
                bus.signal_unsubscribe(track_list_subscription_id);
                track_list_subscription_id = 0;
            }
            if (seeked_subscription_id != 0) {
                bus.signal_unsubscribe(seeked_subscription_id);
                seeked_subscription_id = 0;
            }
        }

        public async Variant get_all(string interface_name, Cancellable? cancellable = null) throws Error {
            Variant result = yield call_async(PROPERTIES_IFACE, "GetAll",
                new Variant("(s)", interface_name), new VariantType("(a{sv})"), cancellable);
            return result.get_child_value(0);
        }

        public async Variant read_property_async(
            string interface_name, string property_name, Cancellable? cancellable = null
        ) throws Error {
            Variant result = yield call_async(PROPERTIES_IFACE, "Get",
                new Variant("(ss)", interface_name, property_name), new VariantType("(v)"), cancellable);
            return result.get_child_value(0).get_variant();
        }

        public async void write_property(
            string interface_name, string property_name, Variant value, Cancellable? cancellable = null
        ) throws Error {
            yield call_async(PROPERTIES_IFACE, "Set", new Variant("(ssv)", interface_name, property_name, value),
                new VariantType("()"), cancellable);
        }

        public async Variant call_async(
            string interface_name, string method_name, Variant? parameters,
            VariantType? reply_type = null, Cancellable? cancellable = null
        ) throws Error {
            if (lifetime.is_cancelled()) {
                throw new IOError.CANCELLED("MPRIS player disconnected");
            }
            var request = cancellable ?? new Cancellable();
            ulong cancellation_handler = lifetime.cancelled.connect(request.cancel);
            try {
                return yield bus.call(owner, OBJECT_PATH, interface_name, method_name, parameters,
                    reply_type, DBusCallFlags.NO_AUTO_START, CALL_TIMEOUT_MS, request);
            } finally {
                SignalHandler.disconnect(lifetime, cancellation_handler);
            }
        }

        private void on_properties_changed(
            DBusConnection connection, string? sender, string path,
            string interface_name, string signal_name, Variant parameters
        ) {
            if (lifetime.is_cancelled() || sender != owner
                || !parameters.is_of_type(new VariantType("(sa{sv}as)"))) {
                return;
            }
            string changed_interface;
            Variant changed;
            Variant invalidated;
            parameters.get("(s@a{sv}@as)", out changed_interface, out changed, out invalidated);
            properties_changed(changed_interface, changed, invalidated);
        }

        private void on_track_list_signal(
            DBusConnection connection, string? sender, string path,
            string interface_name, string signal_name, Variant parameters
        ) {
            if (lifetime.is_cancelled() || sender != owner) {
                return;
            }
            switch (signal_name) {
                case "TrackListReplaced":
                case "TrackAdded":
                case "TrackRemoved":
                case "TrackMetadataChanged":
                    track_list_changed();
                    break;
            }
        }

        private void on_seeked(
            DBusConnection connection, string? sender, string path,
            string interface_name, string signal_name, Variant parameters
        ) {
            if (!lifetime.is_cancelled() && sender == owner && parameters.is_of_type(new VariantType("(x)"))) {
                seeked(int64.max(0, parameters.get_child_value(0).get_int64()));
            }
        }
    }
}
