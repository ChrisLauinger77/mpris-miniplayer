private const string ROOT_IFACE = "org.mpris.MediaPlayer2";
private const string PLAYER_IFACE = "org.mpris.MediaPlayer2.Player";
private const string TRACKLIST_IFACE = "org.mpris.MediaPlayer2.TrackList";

private void drain_main_context() {
    MainContext context = MainContext.default();
    while (context.pending()) {
        context.iteration(false);
    }
}

private class FakeTransport : Object, MprisMiniPlayer.MprisTransport {
    public bool shuffle = false;
    public string loop_status = "None";
    public bool has_track_list = true;
    public string[] track_ids = {
        "/org/mpris/MediaPlayer2/track/one",
        "/org/mpris/MediaPlayer2/track/two",
        "/org/mpris/MediaPlayer2/track/three"
    };
    public string last_property = "";
    public string last_go_to = "";
    public int queue_reads = 0;
    public int[] metadata_batch_sizes = {};

    public Variant get_all(string interface_name) throws Error {
        var properties = new VariantBuilder(new VariantType("a{sv}"));
        if (interface_name == ROOT_IFACE) {
            properties.add("{sv}", "Identity", new Variant.string("Test Player"));
            properties.add("{sv}", "HasTrackList", new Variant.boolean(has_track_list));
        } else if (interface_name == PLAYER_IFACE) {
            properties.add("{sv}", "PlaybackStatus", new Variant.string("Playing"));
            properties.add("{sv}", "CanControl", new Variant.boolean(true));
            properties.add("{sv}", "CanPlay", new Variant.boolean(true));
            properties.add("{sv}", "CanPause", new Variant.boolean(true));
            properties.add("{sv}", "Shuffle", new Variant.boolean(shuffle));
            properties.add("{sv}", "LoopStatus", new Variant.string(loop_status));
            properties.add("{sv}", "Metadata", current_metadata());
        }
        return properties.end();
    }

    public Variant read_property(string interface_name, string property_name) throws Error {
        if (interface_name == TRACKLIST_IFACE && property_name == "Tracks") {
            queue_reads++;
            return new Variant.objv(track_ids);
        }
        if (interface_name == PLAYER_IFACE && property_name == "Position") {
            return new Variant.int64(0);
        }
        throw new IOError.NOT_SUPPORTED("Unsupported test property");
    }

    public async Variant read_property_async(
        string interface_name,
        string property_name
    ) throws Error {
        return read_property(interface_name, property_name);
    }

    public void write_property(
        string interface_name,
        string property_name,
        Variant value
    ) throws Error {
        assert_cmpstr(interface_name, CompareOperator.EQ, PLAYER_IFACE);
        last_property = property_name;
        if (property_name == "Shuffle") {
            shuffle = value.get_boolean();
        } else if (property_name == "LoopStatus") {
            loop_status = value.get_string();
        }
    }

    public Variant call(
        string interface_name,
        string method_name,
        Variant? parameters,
        VariantType? reply_type = null
    ) throws Error {
        if (interface_name == TRACKLIST_IFACE && method_name == "GetTracksMetadata") {
            assert_nonnull(parameters);
            Variant requested_ids = parameters.get_child_value(0);
            metadata_batch_sizes += (int) requested_ids.n_children();
            var metadata = new VariantBuilder(new VariantType("aa{sv}"));
            for (size_t index = 0; index < requested_ids.n_children(); index++) {
                string id = requested_ids.get_child_value(index).get_string();
                metadata.add_value(metadata_for_track(id));
            }
            return new Variant.tuple({ metadata.end() });
        }
        if (interface_name == TRACKLIST_IFACE && method_name == "GoTo") {
            assert_nonnull(parameters);
            last_go_to = parameters.get_child_value(0).get_string();
        }
        return new Variant.tuple({});
    }

    public async Variant call_async(
        string interface_name,
        string method_name,
        Variant? parameters,
        VariantType? reply_type = null
    ) throws Error {
        return call(interface_name, method_name, parameters, reply_type);
    }

    public void emit_player_state(bool shuffle, string loop_status) {
        this.shuffle = shuffle;
        this.loop_status = loop_status;
        var properties = new VariantBuilder(new VariantType("a{sv}"));
        properties.add("{sv}", "Shuffle", new Variant.boolean(shuffle));
        properties.add("{sv}", "LoopStatus", new Variant.string(loop_status));
        properties_changed(PLAYER_IFACE, properties.end(), new Variant.strv({}));
    }

    public void replace_queue(string[] ids) {
        track_ids = ids;
        track_list_changed();
    }

    public void set_track_list_available(bool available) {
        has_track_list = available;
        var properties = new VariantBuilder(new VariantType("a{sv}"));
        properties.add("{sv}", "HasTrackList", new Variant.boolean(available));
        properties_changed(ROOT_IFACE, properties.end(), new Variant.strv({}));
    }

    private Variant current_metadata() {
        var metadata = new VariantBuilder(new VariantType("a{sv}"));
        metadata.add(
            "{sv}",
            "mpris:trackid",
            new Variant.object_path("/org/mpris/MediaPlayer2/track/two")
        );
        metadata.add("{sv}", "xesam:title", new Variant.string("Same title"));
        metadata.add("{sv}", "xesam:artist", new Variant.strv({ "Artist" }));
        return metadata.end();
    }

    private Variant metadata_for_track(string id) {
        var metadata = new VariantBuilder(new VariantType("a{sv}"));
        string title = id.has_suffix("three") ? "Third" : "Same title";
        metadata.add("{sv}", "mpris:trackid", new Variant.object_path(id));
        metadata.add("{sv}", "xesam:title", new Variant.string(title));
        metadata.add("{sv}", "xesam:artist", new Variant.strv({ "Artist" }));
        return metadata.end();
    }
}

private void test_initial_state_and_queue() {
    var transport = new FakeTransport();
    var player = new MprisMiniPlayer.MprisPlayer.with_transport("test", transport);
    drain_main_context();

    assert_true(player.has_shuffle);
    assert_false(player.shuffle);
    assert_true(player.has_loop_status);
    assert_cmpstr(player.loop_status, CompareOperator.EQ, "None");
    assert_true(player.has_track_list);
    assert_cmpint(player.queue.length, CompareOperator.EQ, 3);
    assert_cmpstr(player.queue[0].title, CompareOperator.EQ, "Same title");
    assert_cmpstr(player.queue[1].title, CompareOperator.EQ, "Same title");
    assert_cmpstr(player.queue[2].title, CompareOperator.EQ, "Third");
}

private void test_shuffle_and_repeat_updates() {
    var transport = new FakeTransport();
    var player = new MprisMiniPlayer.MprisPlayer.with_transport("test", transport);
    drain_main_context();

    player.toggle_shuffle();
    assert_true(player.shuffle);
    assert_cmpstr(transport.last_property, CompareOperator.EQ, "Shuffle");

    player.cycle_loop_status();
    assert_cmpstr(player.loop_status, CompareOperator.EQ, "Track");
    player.cycle_loop_status();
    assert_cmpstr(player.loop_status, CompareOperator.EQ, "Playlist");
    player.cycle_loop_status();
    assert_cmpstr(player.loop_status, CompareOperator.EQ, "None");

    transport.emit_player_state(false, "Track");
    assert_false(player.shuffle);
    assert_cmpstr(player.loop_status, CompareOperator.EQ, "Track");
}

private void test_queue_signals_and_go_to() {
    var transport = new FakeTransport();
    var player = new MprisMiniPlayer.MprisPlayer.with_transport("test", transport);
    drain_main_context();
    int initial_reads = transport.queue_reads;

    assert_true(player.go_to("/org/mpris/MediaPlayer2/track/three"));
    assert_cmpstr(
        transport.last_go_to,
        CompareOperator.EQ,
        "/org/mpris/MediaPlayer2/track/three"
    );
    assert_false(player.go_to("/org/mpris/MediaPlayer2/track/stale"));
    assert_true(transport.queue_reads > initial_reads);

    transport.replace_queue({ "/org/mpris/MediaPlayer2/track/three" });
    drain_main_context();
    assert_cmpint(player.queue.length, CompareOperator.EQ, 1);
    assert_cmpstr(
        player.queue[0].id,
        CompareOperator.EQ,
        "/org/mpris/MediaPlayer2/track/three"
    );

    transport.set_track_list_available(false);
    assert_false(player.has_track_list);
    assert_cmpint(player.queue.length, CompareOperator.EQ, 0);
    assert_false(player.go_to("/org/mpris/MediaPlayer2/track/three"));
}

private void test_repeat_cycle_helper() {
    assert_cmpstr(
        MprisMiniPlayer.MprisPlayer.next_loop_status("None"),
        CompareOperator.EQ,
        "Track"
    );
    assert_cmpstr(
        MprisMiniPlayer.MprisPlayer.next_loop_status("Track"),
        CompareOperator.EQ,
        "Playlist"
    );
    assert_cmpstr(
        MprisMiniPlayer.MprisPlayer.next_loop_status("Playlist"),
        CompareOperator.EQ,
        "None"
    );
}

private void test_large_queue_metadata_is_batched() {
    var transport = new FakeTransport();
    string[] track_ids = new string[145];
    for (int index = 0; index < track_ids.length; index++) {
        track_ids[index] = "/org/mpris/MediaPlayer2/track/item_%d".printf(index);
    }
    transport.track_ids = track_ids;

    var player = new MprisMiniPlayer.MprisPlayer.with_transport("test", transport);
    drain_main_context();
    assert_cmpint(player.queue.length, CompareOperator.EQ, track_ids.length);
    assert_cmpint(transport.metadata_batch_sizes.length, CompareOperator.EQ, 3);
    foreach (int batch_size in transport.metadata_batch_sizes) {
        assert_true(batch_size > 0);
        assert_true(batch_size <= 64);
    }
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/mpris-player/initial-state-and-queue", test_initial_state_and_queue);
    Test.add_func("/mpris-player/shuffle-repeat-updates", test_shuffle_and_repeat_updates);
    Test.add_func("/mpris-player/queue-signals-and-go-to", test_queue_signals_and_go_to);
    Test.add_func("/mpris-player/repeat-cycle-helper", test_repeat_cycle_helper);
    Test.add_func(
        "/mpris-player/large-queue-metadata-is-batched",
        test_large_queue_metadata_is_batched
    );
    return Test.run();
}
