// These tests use only the private bus started by Meson, never the desktop bus.
private const string PATH = "/org/mpris/MediaPlayer2";
private const string PLAYER_IFACE = "org.mpris.MediaPlayer2.Player";
private const string NAME_A = "org.mpris.MediaPlayer2.reliability_a";
private const string NAME_B = "org.mpris.MediaPlayer2.reliability_b";

[DBus (name = "org.mpris.MediaPlayer2")]
private class MockRoot : Object {
    public string identity { owned get { return "Same identity"; } }
    public bool has_track_list { get { return false; } }
}

[DBus (name = "org.mpris.MediaPlayer2.Player")]
private class MockPlayer : Object {
    public string state = "Playing";
    public string title = "Same title";
    public bool hold_pause = false;
    public int pause_calls = 0;
    public bool fail_pause = false;
    private SourceFunc? pause_callback;
    public string playback_status { owned get { return state; } }
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
    return Test.run();
}
