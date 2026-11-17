// These tests use only the private bus started by Meson, never the desktop bus.
private const string PATH = "/org/mpris/MediaPlayer2";
private const string PLAYER_IFACE = "org.mpris.MediaPlayer2.Player";
private const string NAME_A = "org.mpris.MediaPlayer2.reliability_a";
private const string NAME_B = "org.mpris.MediaPlayer2.reliability_b";
private const string AMBEROL_ID = "io.bassi.Amberol";
private const string OTHER_ID = "io.bassi.OtherPlayer";
private const string AMBEROL_NAME = "org.mpris.MediaPlayer2.io.bassi.Amberol";
private const string OTHER_NAME = "org.mpris.MediaPlayer2.io.bassi.OtherPlayer";

[DBus (name = "org.mpris.MediaPlayer2")]
private class MockRoot : Object {
    public string label = "Same identity";
    public string desktop_id = "";
    public int reads = 0;
    public string identity { owned get { reads++; return label; } }
    public string desktop_entry { owned get { return desktop_id; } }
    public bool has_track_list { get { return false; } }
}

[DBus (name = "org.mpris.MediaPlayer2.Player")]
private class MockPlayer : Object {
    public string state = "Playing";
    public string title = "Same title";
    public bool hold_pause = false;
    public int pause_calls = 0;
    public bool fail_pause = false;
    public int reads = 0;
    private SourceFunc? pause_callback;
    public string playback_status { owned get { reads++; return state; } }
    public bool can_control { get { return true; } }
    public bool can_play { get { return true; } }
    public bool can_pause { get { return true; } }
    public int64 position { get { return 0; } }
    public HashTable<string, Variant> metadata {
        owned get {
            var result = new HashTable<string, Variant>(str_hash, str_equal);
            result.insert("mpris:trackid", new Variant.object_path("/track/same"));
            result.insert("xesam:title", new Variant.string(title));
            return result;
        }
    }
    public async void pause() throws DBusError, IOError {
        pause_calls++;
        if (hold_pause) { pause_callback = pause.callback; yield; }
        if (fail_pause) throw new DBusError.FAILED("Injected remote failure");
    }
    [DBus (visible = false)]
    public void release_pause() {
        if (pause_callback != null) Idle.add((owned) pause_callback);
    }
}

private delegate bool Condition();
private void wait_until(Condition condition, uint timeout_ms = 5000) {
    bool expired = false;
    uint timer = Timeout.add(timeout_ms, () => { expired = true; return Source.REMOVE; });
    while (!condition() && !expired) MainContext.default().iteration(true);
    if (!expired) Source.remove(timer);
    assert_false(expired);
}

private void drain() {
    while (MainContext.default().pending()) MainContext.default().iteration(false);
}

private DBusConnection connection() throws Error {
    return new DBusConnection.for_address_sync(Environment.get_variable("DBUS_SESSION_BUS_ADDRESS"),
        DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION);
}

private void own(DBusConnection bus, string name, bool replace = false) throws Error {
    Variant reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
        "RequestName", new Variant("(su)", name, (uint) (replace ? 6 : 5)), new VariantType("(u)"), DBusCallFlags.NONE, 3000);
    assert_cmpuint(reply.get_child_value(0).get_uint32(), CompareOperator.EQ, 1);
}

private void release(DBusConnection bus, string name) throws Error {
    bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ReleaseName",
        new Variant("(s)", name), new VariantType("(u)"), DBusCallFlags.NONE, 3000);
}

private void emit_state(DBusConnection bus, MockPlayer mock) throws Error {
    var props = new VariantBuilder(new VariantType("a{sv}"));
    props.add("{sv}", "PlaybackStatus", new Variant.string(mock.state));
    var metadata = new VariantBuilder(new VariantType("a{sv}"));
    metadata.add("{sv}", "mpris:trackid", new Variant.object_path("/track/same"));
    metadata.add("{sv}", "xesam:title", new Variant.string(mock.title));
    props.add("{sv}", "Metadata", metadata.end());
    bus.emit_signal(null, PATH, "org.freedesktop.DBus.Properties", "PropertiesChanged",
        new Variant("(s@a{sv}@as)", PLAYER_IFACE, props.end(), new Variant.strv({})));
}

// Filters run on GDBus's worker thread. Only the atomic count is shared with
// the main loop; copying the message preserves its serial and reply routing.
private class ListNamesFault : Object {
    private int attempts = 0;
    private int failures;
    public int calls { get { return AtomicInt.get(ref attempts); } }

    public ListNamesFault(int failures) {
        this.failures = failures;
    }

    public DBusMessage? filter(DBusConnection connection, owned DBusMessage message, bool incoming) {
        if (!incoming && message.get_destination() == "org.freedesktop.DBus"
            && message.get_member() == "ListNames") {
            int attempt = AtomicInt.add(ref attempts, 1);
            if (attempt < failures) {
                try {
                    var failed = message.copy();
                    failed.set_member("InjectedListNamesFailure");
                    return failed;
                } catch (Error error) {
                    assert_not_reached();
                }
            }
        }
        return (owned) message;
    }
}

private class MockService : Object {
    public DBusConnection bus;
    public MockRoot root = new MockRoot();
    public MockPlayer player = new MockPlayer();
    private uint root_registration;
    private uint player_registration;

    public MockService() throws Error {
        bus = connection();
        root_registration = bus.register_object(PATH, root);
        player_registration = bus.register_object(PATH, player);
    }

    public void close() throws Error {
        bus.unregister_object(player_registration);
        bus.unregister_object(root_registration);
        bus.close_sync();
    }
}

private MprisMiniPlayer.MprisApplication? find_application(MprisMiniPlayer.MprisManager manager, string id) {
    foreach (var app in manager.list_applications()) if (app.id == id) return app;
    return null;
}

private void test_application_identifiers() {
    string[] names = {
        "vlc", "vlc.instance123", "io.bassi.Amberol", "io.bassi.Amberol.instance123",
        "io.bassi.OtherPlayer", "org.gnome.Rhythmbox", "io.example.instanceViewer",
        "io.example.instance", "io.example.instance123x", "io.example.instance123.tools"
    };
    string[] expected = {
        "vlc", "vlc", "io.bassi.Amberol", "io.bassi.Amberol",
        "io.bassi.OtherPlayer", "org.gnome.Rhythmbox", "io.example.instanceViewer",
        "io.example.instance", "io.example.instance123x", "io.example.instance123.tools"
    };
    for (int i = 0; i < names.length; i++) {
        assert_cmpstr(MprisMiniPlayer.MprisManager.application_id("org.mpris.MediaPlayer2." + names[i]),
            CompareOperator.EQ, expected[i]);
    }
}

private void test_blacklist_dotted_applications() {
    try {
        var client = connection();
        var amberol = new MockService();
        var other = new MockService();
        amberol.root.label = "Amberol";
        other.root.label = "Other player";
        other.player.state = "Paused";
        own(amberol.bus, AMBEROL_NAME);
        own(amberol.bus, AMBEROL_NAME + ".instance123");
        own(other.bus, OTHER_NAME);
        own(other.bus, OTHER_NAME + ".instance234");
        var manager = new MprisMiniPlayer.MprisManager.with_connection(client);
        wait_until(() => manager.ready && manager.active_player != null);
        assert_cmpint(manager.list_applications().length, CompareOperator.EQ, 2);
        assert_true(find_application(manager, AMBEROL_ID).running);
        assert_true(find_application(manager, OTHER_ID).running);
        assert_null(find_application(manager, "io"));
        var other_model = manager.get_player(OTHER_NAME);
        manager.select_player(AMBEROL_NAME);
        manager.set_blacklisted_players({ AMBEROL_ID });
        assert_null(manager.get_player(AMBEROL_NAME));
        assert_null(manager.get_player(AMBEROL_NAME + ".instance123"));
        assert_true(manager.get_player(OTHER_NAME) == other_model);
        assert_true(other_model.available);
        assert_cmpint(manager.list_players().length, CompareOperator.EQ, 2);
        assert_cmpstr(manager.active_player.owner, CompareOperator.EQ, other.bus.get_unique_name());
        assert_cmpstr(find_application(manager, AMBEROL_ID).display_name, CompareOperator.EQ, "Amberol");
        assert_cmpstr(find_application(manager, OTHER_ID).display_name, CompareOperator.EQ, "Other player");

        // Simulate a restart with the saved full identifier. Ignored models
        // must not be created, while the sibling application remains usable.
        manager.shutdown();
        int ignored_reads = amberol.player.reads + amberol.root.reads;
        manager = new MprisMiniPlayer.MprisManager.with_connection(client, { AMBEROL_ID });
        wait_until(() => manager.ready && manager.active_player != null);
        assert_cmpint(manager.list_applications().length, CompareOperator.EQ, 2);
        assert_cmpint(manager.list_players().length, CompareOperator.EQ, 2);
        assert_null(manager.get_player(AMBEROL_NAME));
        assert_cmpstr(manager.active_player.owner, CompareOperator.EQ, other.bus.get_unique_name());
        assert_cmpint(amberol.player.reads + amberol.root.reads, CompareOperator.EQ, ignored_reads);
        release(amberol.bus, AMBEROL_NAME);
        release(amberol.bus, AMBEROL_NAME + ".instance123");
        wait_until(() => !find_application(manager, AMBEROL_ID).running);
        own(amberol.bus, AMBEROL_NAME + ".instance456");
        wait_until(() => find_application(manager, AMBEROL_ID).running);
        assert_null(manager.get_player(AMBEROL_NAME + ".instance456"));
        assert_cmpint(amberol.player.reads + amberol.root.reads, CompareOperator.EQ, ignored_reads);
        manager.set_blacklisted_players({ OTHER_ID });
        wait_until(() => manager.active_player != null && manager.active_player.initialized);
        assert_cmpstr(manager.active_player.bus_name, CompareOperator.EQ, AMBEROL_NAME + ".instance456");
        assert_null(manager.get_player(OTHER_NAME));
        assert_null(manager.get_player(OTHER_NAME + ".instance234"));
        manager.shutdown();
        amberol.close(); other.close(); client.close_sync();
        drain();
    } catch (Error error) {
        Test.fail_printf("Blacklist dotted applications: %s", error.message);
    }
}

private void test_blacklist_startup_and_instances() {
    try {
        var client = connection();
        var ignored = new MockService();
        var allowed = new MockService();
        string instance = NAME_A + ".instance123";
        string similar = NAME_A + "2";
        string uppercase = "org.mpris.MediaPlayer2.Reliability_a";
        own(ignored.bus, NAME_A);
        own(ignored.bus, instance);
        own(allowed.bus, NAME_B);
        own(allowed.bus, similar);
        own(allowed.bus, uppercase);
        var manager = new MprisMiniPlayer.MprisManager.with_connection(client, { "reliability_a", "offline" });
        wait_until(() => manager.ready && manager.active_player != null);
        assert_cmpint(manager.list_players().length, CompareOperator.EQ, 3);
        assert_null(manager.get_player(NAME_A));
        assert_null(manager.get_player(instance));
        assert_nonnull(manager.get_player(similar));
        assert_nonnull(manager.get_player(uppercase));
        assert_cmpint(ignored.root.reads, CompareOperator.EQ, 0);
        assert_cmpint(ignored.player.reads, CompareOperator.EQ, 0);
        assert_cmpint(manager.list_applications().length, CompareOperator.EQ, 5);
        assert_true(find_application(manager, "reliability_a").running);
        assert_false(find_application(manager, "offline").running);

        int membership_changes = 0;
        ulong membership_handler = manager.players_changed.connect(() => membership_changes++);
        // Another instance of the ignored application changes only the catalog.
        own(ignored.bus, NAME_A + ".instance456");
        release(ignored.bus, NAME_A);
        release(ignored.bus, instance);
        // An owner lookup on this connection is a barrier for the preceding events.
        release(ignored.bus, NAME_A + ".instance456");
        wait_until(() => !find_application(manager, "reliability_a").running);
        assert_cmpint(membership_changes, CompareOperator.EQ, 0);
        assert_cmpint(ignored.player.reads, CompareOperator.EQ, 0);
        own(ignored.bus, instance);
        wait_until(() => find_application(manager, "reliability_a").running);
        manager.set_blacklisted_players({ "offline" });
        wait_until(() => manager.get_player(instance) != null && manager.get_player(instance).initialized);
        wait_until(() => find_application(manager, "reliability_a").display_name == "Same identity");
        assert_cmpint(manager.list_players().length, CompareOperator.EQ, 4);
        assert_true(ignored.player.reads > 0);
        assert_cmpstr(find_application(manager, "reliability_a").display_name, CompareOperator.EQ, "Same identity");
        SignalHandler.disconnect(manager, membership_handler);
        manager.shutdown();
        ignored.close(); allowed.close(); client.close_sync();
        drain();
    } catch (Error error) {
        Test.fail_printf("Blacklist startup and instances: %s", error.message);
    }
}

private void test_blacklist_active_replacement_and_restore() {
    try {
        var client = connection();
        var first = new MockService();
        var second = new MockService();
        var replacement = new MockService();
        first.root.label = "First player";
        first.root.desktop_id = "first-player";
        second.player.state = "Paused";
        replacement.player.title = "Replacement";
        own(first.bus, NAME_A);
        own(second.bus, NAME_B);
        var manager = new MprisMiniPlayer.MprisManager.with_connection(client);
        wait_until(() => manager.ready && manager.active_player != null);
        manager.select_player(NAME_A);
        var old = manager.active_player;
        var weak_old = WeakRef(old);
        first.player.hold_pause = true;
        old.play_pause();
        wait_until(() => first.player.pause_calls == 1);
        manager.set_blacklisted_players({ "reliability_a" });
        assert_false(old.available);
        assert_null(manager.get_player(NAME_A));
        assert_cmpstr(manager.active_player.bus_name, CompareOperator.EQ, NAME_B);
        manager.select_player(NAME_A);
        assert_cmpstr(manager.active_player.bus_name, CompareOperator.EQ, NAME_B);
        old.play_pause();
        assert_cmpint(first.player.pause_calls, CompareOperator.EQ, 1);
        first.player.release_pause();
        old = null;
        wait_until(() => weak_old.get() == null);
        assert_cmpstr(find_application(manager, "reliability_a").display_name, CompareOperator.EQ, "First player");
        assert_cmpstr(find_application(manager, "reliability_a").icon_name, CompareOperator.EQ, "first-player");

        own(replacement.bus, NAME_A, true);
        // A second name forms a barrier after the blocked owner replacement.
        own(replacement.bus, NAME_A + ".instance789");
        release(replacement.bus, NAME_A);
        wait_until(() => find_application(manager, "reliability_a").running && manager.get_player(NAME_A) == null);
        drain();
        assert_cmpint(replacement.root.reads, CompareOperator.EQ, 0);
        assert_cmpint(replacement.player.reads, CompareOperator.EQ, 0);
        manager.set_blacklisted_players({});
        wait_until(() => manager.get_player(NAME_A + ".instance789") != null
            && manager.get_player(NAME_A + ".instance789").initialized);
        assert_cmpstr(manager.active_player.owner, CompareOperator.EQ, replacement.bus.get_unique_name());
        assert_cmpstr(manager.active_player.title, CompareOperator.EQ, "Replacement");
        manager.set_blacklisted_players({ "reliability_a", "reliability_b" });
        assert_null(manager.active_player);
        assert_cmpint(manager.list_players().length, CompareOperator.EQ, 0);
        release(replacement.bus, NAME_A + ".instance789");
        wait_until(() => !find_application(manager, "reliability_a").running);
        // Restoring an offline application removes its saved Preferences row.
        manager.set_blacklisted_players({ "reliability_b" });
        assert_null(find_application(manager, "reliability_a"));
        var weak_manager = WeakRef(manager);
        manager.shutdown();
        manager.set_blacklisted_players({});
        assert_null(manager.active_player);
        manager = null;
        wait_until(() => weak_manager.get() == null);
        first.close(); second.close(); replacement.close(); client.close_sync();
        drain();
    } catch (Error error) {
        Test.fail_printf("Blacklist active replacement and restore: %s", error.message);
    }
}

// Hold one reply on the GDBus worker while the main loop changes the blacklist
// or shuts down. A deadline prevents a broken test from retaining the worker.
private class ReplyGate : Object {
    private string member;
    private uint serial = 0;
    private Mutex mutex;
    private Cond condition;
    private bool released = false;
    private int arrived = 0;
    public bool waiting { get { return AtomicInt.get(ref arrived) != 0; } }

    public ReplyGate(string member) {
        this.member = member;
    }

    public void release() {
        mutex.lock();
        released = true;
        condition.signal();
        mutex.unlock();
    }

    public DBusMessage? filter(DBusConnection connection, owned DBusMessage message, bool incoming) {
        if (!incoming && serial == 0 && message.get_member() == member) serial = message.get_serial();
        if (incoming && serial != 0 && message.get_reply_serial() == serial) {
            mutex.lock();
            AtomicInt.set(ref arrived, 1);
            Idle.add(() => Source.REMOVE);
            int64 deadline = get_monotonic_time() + 5 * TimeSpan.SECOND;
            while (!released && condition.wait_until(mutex, deadline)) {}
            mutex.unlock();
        }
        return (owned) message;
    }
}

private void test_blacklist_pending_discovery_and_snapshot() {
    try {
        foreach (var member in new string[] { "GetNameOwner", "GetAll" }) {
            for (int shutdown = 0; shutdown < 2; shutdown++) {
                var client = connection();
                var server = new MockService();
                own(server.bus, NAME_A);
                var gate = new ReplyGate(member);
                uint filter = client.add_filter(gate.filter);
                var manager = new MprisMiniPlayer.MprisManager.with_connection(client);
                wait_until(() => gate.waiting);
                manager.set_blacklisted_players({ "reliability_a" });
                if (shutdown != 0) manager.shutdown();
                gate.release();
                if (shutdown == 0) wait_until(() => manager.ready);
                drain();
                assert_null(manager.active_player);
                assert_null(manager.get_player(NAME_A));
                assert_cmpint(manager.list_players().length, CompareOperator.EQ, 0);
                if (member == "GetNameOwner") {
                    assert_cmpint(server.root.reads, CompareOperator.EQ, 0);
                    assert_cmpint(server.player.reads, CompareOperator.EQ, 0);
                }
                if (shutdown == 0) {
                    assert_true(find_application(manager, "reliability_a").running);
                    manager.set_blacklisted_players({});
                    wait_until(() => manager.active_player != null && manager.active_player.initialized);
                }
                manager.shutdown();
                client.remove_filter(filter);
                var weak_manager = WeakRef(manager);
                manager = null;
                wait_until(() => weak_manager.get() == null);
                server.close(); client.close_sync();
                drain();
            }
        }
    } catch (Error error) {
        Test.fail_printf("Blacklist discovery and snapshot races: %s", error.message);
    }
}

private void test_list_names_retry_finds_stable_players() {
    try {
        var client = connection();
        var server = connection();
        var later_server = connection();
        var root = new MockRoot();
        var stable = new MockPlayer();
        var later = new MockPlayer();
        later.state = "Paused";
        uint stable_root = server.register_object(PATH, root);
        uint stable_player = server.register_object(PATH, stable);
        uint later_root = later_server.register_object(PATH, root);
        uint later_player = later_server.register_object(PATH, later);
        own(server, NAME_A); // This owner never changes while discovery retries.
        var fault = new ListNamesFault(2);
        uint filter = client.add_filter(fault.filter);
        var manager = new MprisMiniPlayer.MprisManager.with_connection(client);
        int errors = 0;
        int completions = 0;
        manager.operation_failed.connect((operation, error) => {
            assert_cmpstr(operation, CompareOperator.EQ, "Discover players");
            assert_true(error is DBusError.UNKNOWN_METHOD);
            assert_true(error.message.contains("InjectedListNamesFailure"));
            errors++;
        });
        manager.discovery_finished.connect(() => completions++);
        wait_until(() => manager.ready && manager.discovery_failed);
        assert_true(manager.connected);
        assert_null(manager.get_player(NAME_A));
        own(later_server, NAME_B); // The subscription stays live during backoff.
        wait_until(() => manager.get_player(NAME_B) != null && manager.get_player(NAME_B).available);
        var known = manager.get_player(NAME_B);
        manager.select_player(NAME_B);
        wait_until(() => manager.get_player(NAME_A) != null && manager.get_player(NAME_A).available, 10000);
        assert_cmpint(errors, CompareOperator.EQ, 2);
        assert_cmpint(fault.calls, CompareOperator.EQ, 3);
        assert_cmpint(completions, CompareOperator.EQ, 1);
        assert_true(manager.get_player(NAME_B) == known);
        assert_true(manager.active_player == known);
        assert_false(manager.discovery_failed);
        manager.shutdown();
        client.remove_filter(filter);
        release(server, NAME_A);
        release(later_server, NAME_B);
        server.unregister_object(stable_player);
        server.unregister_object(stable_root);
        later_server.unregister_object(later_player);
        later_server.unregister_object(later_root);
        server.close_sync(); later_server.close_sync(); client.close_sync();
        drain();
    } catch (Error error) {
        Test.fail_printf("Discovery retry test: %s", error.message);
    }
}

private void test_list_names_retry_clears_empty_error() {
    try {
        var client = connection();
        var fault = new ListNamesFault(1);
        uint filter = client.add_filter(fault.filter);
        var manager = new MprisMiniPlayer.MprisManager.with_connection(client);
        wait_until(() => manager.ready && manager.discovery_failed);
        bool view_failed = true;
        ulong changed_handler = manager.players_updated.connect(() => view_failed = manager.discovery_failed);
        wait_until(() => !manager.discovery_failed && !view_failed);
        assert_true(manager.connected);
        assert_true(manager.ready);
        assert_cmpint(manager.list_players().length, CompareOperator.EQ, 0);
        assert_cmpint(fault.calls, CompareOperator.EQ, 2);
        SignalHandler.disconnect(manager, changed_handler);
        manager.shutdown();
        client.remove_filter(filter);
        client.close_sync();
        drain();
    } catch (Error error) {
        Test.fail_printf("Empty discovery recovery test: %s", error.message);
    }
}

private void test_list_names_retry_shutdown() {
    try {
        for (int reentrant = 0; reentrant < 2; reentrant++) {
            var client = connection();
            var fault = new ListNamesFault(100);
            uint filter = client.add_filter(fault.filter);
            var manager = new MprisMiniPlayer.MprisManager.with_connection(client);
            int errors = 0;
            ulong error_handler = manager.operation_failed.connect(() => {
                errors++;
                if (reentrant != 0) manager.shutdown();
            });
            wait_until(() => errors == 1);
            if (reentrant == 0) {
                assert_true(manager.ready);
                manager.shutdown(); // A retry is already scheduled.
            } else {
                assert_false(manager.ready); // No startup publication after shutdown.
            }
            SignalHandler.disconnect(manager, error_handler);
            var weak_manager = WeakRef(manager);
            manager = null;
            wait_until(() => weak_manager.get() == null);
            assert_cmpint(fault.calls, CompareOperator.EQ, 1);
            assert_false(client.is_closed());
            client.remove_filter(filter);
            client.close_sync();
            drain();
        }
    } catch (Error error) {
        Test.fail_printf("Discovery retry shutdown test: %s", error.message);
    }
}

private void test_owner_replacement_and_shutdown() {
    try {
        var client = connection();
        var first = connection();
        var second = connection();
        var replacement = connection();
        var root = new MockRoot();
        var a = new MockPlayer();
        var b = new MockPlayer();
        b.state = "Paused";
        var restarted = new MockPlayer();
        restarted.title = "Restarted";
        uint first_root = first.register_object(PATH, root);
        uint first_player = first.register_object(PATH, a);
        uint second_root = second.register_object(PATH, root);
        uint second_player = second.register_object(PATH, b);
        uint replacement_root = replacement.register_object(PATH, root);
        uint replacement_player = replacement.register_object(PATH, restarted);
        own(first, NAME_A);
        own(second, NAME_B);
        var manager = new MprisMiniPlayer.MprisManager.with_connection(client);
        wait_until(() => manager.ready && manager.active_player != null && manager.list_players().length == 2);
        assert_cmpstr(manager.active_player.bus_name, CompareOperator.EQ, NAME_A);
        int membership_changes = 0;
        manager.players_changed.connect(() => membership_changes++);
        manager.select_player(NAME_A); // Clicking the already selected player pins it.
        b.state = "Playing";
        emit_state(second, b);
        wait_until(() => manager.get_player(NAME_B).playback_status == "Playing");
        assert_cmpstr(manager.active_player.bus_name, CompareOperator.EQ, NAME_A);
        drain();
        assert_cmpint(membership_changes, CompareOperator.EQ, 0);

        var old = manager.active_player;
        var weak_old = WeakRef(old);
        a.hold_pause = true;
        old.play_pause();
        wait_until(() => a.pause_calls == 1);
        own(replacement, NAME_A, true);
        wait_until(() => manager.active_player != null && manager.active_player.owner == replacement.get_unique_name());
        assert_false(old.available);
        assert_cmpstr(manager.active_player.title, CompareOperator.EQ, "Restarted");
        old.play_pause();
        assert_cmpint(restarted.pause_calls, CompareOperator.EQ, 0);
        a.title = "Stale owner";
        emit_state(first, a);
        a.release_pause();
        old = null;
        wait_until(() => weak_old.get() == null);
        assert_cmpstr(manager.active_player.title, CompareOperator.EQ, "Restarted");

        restarted.fail_pause = true;
        bool failed = false;
        manager.operation_failed.connect((operation, error) => {
            assert_true(error is DBusError.FAILED);
            assert_true(error.message.contains("Injected remote failure"));
            failed = true;
        });
        manager.active_player.play_pause();
        wait_until(() => failed);
        release(replacement, NAME_A);
        wait_until(() => manager.active_player != null && manager.active_player.bus_name == NAME_B);
        release(second, NAME_B);
        wait_until(() => manager.active_player == null && manager.list_players().length == 0);

        // Rapid churn while GetAll callbacks and subscription removals are pending.
        for (int i = 0; i < 50; i++) {
            string name = "org.mpris.MediaPlayer2.churn_%d".printf(i);
            own(first, name);
            release(first, name);
        }
        first.flush_sync();
        // A final stable name forms a barrier for all preceding owner events.
        own(first, NAME_A);
        wait_until(() => manager.list_players().length == 1 && manager.active_player != null);
        release(first, NAME_A);
        wait_until(() => manager.list_players().length == 0);
        var weak_manager = WeakRef(manager);
        manager.shutdown();
        manager = null;
        wait_until(() => weak_manager.get() == null);

        var transport = new MprisMiniPlayer.DBusMprisTransport(client, first.get_unique_name());
        var weak_transport = WeakRef(transport);
        transport.shutdown();
        transport = null;
        wait_until(() => weak_transport.get() == null);
        first.unregister_object(first_player);
        first.unregister_object(first_root);
        second.unregister_object(second_player);
        second.unregister_object(second_root);
        replacement.unregister_object(replacement_player);
        replacement.unregister_object(replacement_root);
        first.close_sync(); second.close_sync(); replacement.close_sync(); client.close_sync();
        drain();
    } catch (Error error) {
        Test.fail_printf("D-Bus lifecycle test: %s", error.message);
    }
}

[DBus (name = "org.freedesktop.portal.Request")]
private class MockRequest : Object {
    public int closes = 0;
    public void close() throws DBusError, IOError { closes++; }
}

[DBus (name = "org.freedesktop.portal.Background")]
private class MockPortal : Object {
    public DBusConnection bus;
    public string client_name;
    public string last_path = "";
    public int calls = 0;
    public bool last_autostart = false;
    public MockRequest? latest_request;
    private uint[] registrations = {};

    public ObjectPath request_background(string parent, HashTable<string, Variant> options) throws DBusError, IOError {
        calls++;
        last_autostart = options.lookup("autostart").get_boolean();
        string token = options.lookup("handle_token").get_string();
        last_path = "/org/freedesktop/portal/desktop/request/%s/%s".printf(
            client_name.substring(1).replace(".", "_"), token);
        latest_request = new MockRequest();
        registrations += bus.register_object(last_path, latest_request);
        return new ObjectPath(last_path);
    }
    public void set_status(HashTable<string, Variant> options) throws DBusError, IOError {}

    [DBus (visible = false)]
    public void respond(bool background, bool autostart, uint response = 0) throws Error {
        var results = new VariantBuilder(new VariantType("a{sv}"));
        results.add("{sv}", "background", new Variant.boolean(background));
        results.add("{sv}", "autostart", new Variant.boolean(autostart));
        bus.emit_signal(client_name, last_path, "org.freedesktop.portal.Request", "Response",
            new Variant("(u@a{sv})", response, results.end()));
    }
    [DBus (visible = false)]
    public void cleanup() {
        foreach (var id in registrations) bus.unregister_object(id);
        registrations = {};
    }
}

[DBus (name = "org.kde.StatusNotifierWatcher")]
private class MockWatcher : Object {
    public int registrations = 0;
    public string service = "";
    public void register_status_notifier_item(string service) throws DBusError, IOError {
        registrations++;
        this.service = service;
    }
}

private void test_portal_response_restart_and_close() {
    try {
        var client = connection();
        var server = connection();
        var mock = new MockPortal();
        mock.bus = server;
        mock.client_name = client.get_unique_name();
        uint registration = server.register_object("/org/freedesktop/portal/desktop", mock);
        own(server, "org.freedesktop.portal.Desktop");
        var portal = new MprisMiniPlayer.BackgroundPortal.with_connection(client);
        int answers = 0;
        bool enabled = true;
        portal.autostart_changed.connect((value, answered) => { answers++; enabled = value; });
        portal.update_autostart(true);
        wait_until(() => mock.calls == 1);
        mock.respond(false, false);
        wait_until(() => answers == 1);
        assert_false(enabled); // response=0 does not itself grant either permission.
        portal.update_autostart(true);
        wait_until(() => mock.calls == 2);
        mock.respond(true, false);
        wait_until(() => answers == 2);
        portal.update_autostart(true);
        wait_until(() => mock.calls == 3); // Background permission alone cannot satisfy autostart.
        portal.update_autostart(false); // Latest intent must survive a portal restart.
        var old_request = mock.latest_request;
        release(server, "org.freedesktop.portal.Desktop");
        wait_until(() => old_request.closes == 1);
        own(server, "org.freedesktop.portal.Desktop");
        wait_until(() => mock.calls == 4);
        assert_false(mock.last_autostart);
        var pending_request = mock.latest_request;
        var weak_portal = WeakRef(portal);
        portal.shutdown();
        portal = null;
        wait_until(() => pending_request.closes == 1 && weak_portal.get() == null);
        mock.cleanup();
        server.unregister_object(registration);
        release(server, "org.freedesktop.portal.Desktop");
        server.close_sync(); client.close_sync();
        drain();
    } catch (Error error) {
        Test.fail_printf("Portal lifecycle test: %s", error.message);
    }
}

private bool name_owned(DBusConnection bus, string name) {
    try {
        Variant result = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
            "NameHasOwner", new Variant("(s)", name), new VariantType("(b)"), DBusCallFlags.NONE, 3000);
        return result.get_child_value(0).get_boolean();
    } catch (Error error) { assert_not_reached(); }
}

private void test_indicator_name_lifetime() {
    try {
        var client = connection();
        var server = connection();
        var watcher = new MockWatcher();
        uint registration = server.register_object("/StatusNotifierWatcher", watcher);
        own(server, "org.kde.StatusNotifierWatcher");
        var indicator = new MprisMiniPlayer.StatusIndicator.with_connection(client);
        indicator.set_enabled(true);
        wait_until(() => watcher.registrations == 1);
        assert_cmpstr(watcher.service, CompareOperator.NE, client.get_unique_name());
        assert_true(name_owned(client, watcher.service));
        indicator.set_enabled(false);
        wait_until(() => !name_owned(client, watcher.service));
        assert_false(client.is_closed());
        indicator.set_enabled(true);
        wait_until(() => watcher.registrations == 2);
        release(server, "org.kde.StatusNotifierWatcher");
        wait_until(() => !indicator.supported);
        own(server, "org.kde.StatusNotifierWatcher");
        wait_until(() => watcher.registrations == 3);
        var weak_indicator = WeakRef(indicator);
        indicator.shutdown();
        indicator = null;
        wait_until(() => weak_indicator.get() == null && !name_owned(client, watcher.service));
        server.unregister_object(registration);
        release(server, "org.kde.StatusNotifierWatcher");
        server.close_sync(); client.close_sync();
        drain();
    } catch (Error error) {
        Test.fail_printf("Indicator lifecycle test: %s", error.message);
    }
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/mpris-dbus/list-names-retry", test_list_names_retry_finds_stable_players);
    Test.add_func("/mpris-dbus/list-names-empty-recovery", test_list_names_retry_clears_empty_error);
    Test.add_func("/mpris-dbus/list-names-retry-shutdown", test_list_names_retry_shutdown);
    Test.add_func("/desktop-dbus/portal-restart-close", test_portal_response_restart_and_close);
    Test.add_func("/desktop-dbus/indicator-name-lifetime", test_indicator_name_lifetime);
    Test.add_func("/mpris-dbus/owner-replacement-shutdown", test_owner_replacement_and_shutdown);
    Test.add_func("/mpris-dbus/blacklist-startup-instances", test_blacklist_startup_and_instances);
    Test.add_func("/mpris-dbus/application-identifiers", test_application_identifiers);
    Test.add_func("/mpris-dbus/blacklist-dotted-applications", test_blacklist_dotted_applications);
    Test.add_func("/mpris-dbus/blacklist-active-replacement-restore", test_blacklist_active_replacement_and_restore);
    Test.add_func("/mpris-dbus/blacklist-pending-discovery-snapshot", test_blacklist_pending_discovery_and_snapshot);
    return Test.run();
}
