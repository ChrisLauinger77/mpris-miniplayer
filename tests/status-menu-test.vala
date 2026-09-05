private const int ROOT_ID = 0;
private const int SHOW_ID = 1;
private const int HIDE_ID = 2;
private const int PREVIOUS_ID = 20;
private const int PLAY_PAUSE_ID = 21;
private const int NEXT_ID = 22;
private const int SHUFFLE_ID = 23;
private const int REPEAT_ID = 24;
private const int REPEAT_NONE_ID = 25;
private const int REPEAT_TRACK_ID = 26;
private const int REPEAT_PLAYLIST_ID = 27;
private const int VOLUME_ID = 30;
private const int MUTE_ID = 31;
private const int QUEUE_ID = 40;
private const int QUEUE_TRACK_BASE_ID = 1000;
private const string SYMBOLIC_ICON_NAME =
    "io.github.ChrisLauinger.MprisMiniPlayer-symbolic";
private const string ROOT_IFACE = "org.mpris.MediaPlayer2";
private const string PLAYER_IFACE = "org.mpris.MediaPlayer2.Player";
private const string TRACKLIST_IFACE = "org.mpris.MediaPlayer2.TrackList";

private void drain_main_context() {
    MainContext context = MainContext.default();
    while (context.pending()) {
        context.iteration(false);
    }
}

private class StatusMenuTransport : Object, MprisMiniPlayer.MprisTransport {
    public bool shuffle = false;
    public double volume = 0.55;
    public bool hold_volume_write = false;
    private SourceFunc? volume_write_callback;
    public string loop_status = "None";
    public string last_go_to = "";
    public bool expose_loop_status = true;
    public string[] track_ids = {
        "/org/mpris/MediaPlayer2/track/one",
        "/org/mpris/MediaPlayer2/track/two"
    };

    public void shutdown() {}

    public async Variant get_all(string interface_name, Cancellable? cancellable = null) throws Error {
        var properties = new VariantBuilder(new VariantType("a{sv}"));
        if (interface_name == ROOT_IFACE) {
            properties.add("{sv}", "HasTrackList", new Variant.boolean(true));
        } else if (interface_name == PLAYER_IFACE) {
            properties.add("{sv}", "PlaybackStatus", new Variant.string("Playing"));
            properties.add("{sv}", "CanControl", new Variant.boolean(true));
            properties.add("{sv}", "CanPlay", new Variant.boolean(true));
            properties.add("{sv}", "CanPause", new Variant.boolean(true));
            properties.add("{sv}", "Shuffle", new Variant.boolean(shuffle));
            if (expose_loop_status) {
                properties.add("{sv}", "LoopStatus", new Variant.string(loop_status));
            }
            properties.add("{sv}", "Volume", new Variant.double(volume));
            properties.add("{sv}", "Metadata", current_metadata());
        }
        return properties.end();
    }

    public Variant read_property(string interface_name, string property_name) throws Error {
        if (interface_name == TRACKLIST_IFACE && property_name == "Tracks") {
            return new Variant.objv(track_ids);
        }
        if (interface_name == PLAYER_IFACE && property_name == "Position") {
            return new Variant.int64(0);
        }
        if (interface_name == PLAYER_IFACE) {
            if (property_name == "Volume") return new Variant.double(volume);
            if (property_name == "Shuffle") return new Variant.boolean(shuffle);
            if (property_name == "LoopStatus") return new Variant.string(loop_status);
        }
        throw new IOError.NOT_SUPPORTED("Unsupported test property");
    }

    public async Variant read_property_async(
        string interface_name,
        string property_name, Cancellable? cancellable = null
    ) throws Error {
        return read_property(interface_name, property_name);
    }

    public async void write_property(
        string interface_name,
        string property_name,
        Variant value, Cancellable? cancellable = null
    ) throws Error {
        if (property_name == "Volume") {
            if (hold_volume_write) {
                hold_volume_write = false;
                volume_write_callback = write_property.callback;
                yield;
            }
            if (cancellable != null) cancellable.set_error_if_cancelled();
            volume = value.get_double();
        }
        if (property_name == "Shuffle") {
            shuffle = value.get_boolean();
        } else if (property_name == "LoopStatus") {
            loop_status = value.get_string();
        }
    }

    public void release_volume_write() {
        if (volume_write_callback != null) Idle.add((owned) volume_write_callback);
    }

    public Variant call(
        string interface_name,
        string method_name,
        Variant? parameters,
        VariantType? reply_type = null
    ) throws Error {
        if (interface_name == TRACKLIST_IFACE && method_name == "GetTracksMetadata") {
            Variant requested_ids = parameters.get_child_value(0);
            var metadata = new VariantBuilder(new VariantType("aa{sv}"));
            for (size_t index = 0; index < requested_ids.n_children(); index++) {
                string id = requested_ids.get_child_value(index).get_string();
                metadata.add_value(metadata_for_track(id));
            }
            return new Variant.tuple({ metadata.end() });
        }
        if (interface_name == TRACKLIST_IFACE && method_name == "GoTo") {
            last_go_to = parameters.get_child_value(0).get_string();
        }
        return new Variant.tuple({});
    }

    public async Variant call_async(
        string interface_name,
        string method_name,
        Variant? parameters,
        VariantType? reply_type = null, Cancellable? cancellable = null
    ) throws Error {
        return call(interface_name, method_name, parameters, reply_type);
    }

    public void emit_state(bool shuffle, string loop_status) {
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

    public void set_repeat_available(bool available) {
        expose_loop_status = available;
        var properties = new VariantBuilder(new VariantType("a{sv}"));
        if (available) {
            properties.add("{sv}", "LoopStatus", new Variant.string(loop_status));
        }
        string[] invalidated;
        if (available) {
            invalidated = {};
        } else {
            invalidated = { "LoopStatus" };
        }
        properties_changed(
            PLAYER_IFACE,
            properties.end(),
            new Variant.strv(invalidated)
        );
    }

    private Variant current_metadata() {
        var metadata = new VariantBuilder(new VariantType("a{sv}"));
        metadata.add(
            "{sv}",
            "mpris:trackid",
            new Variant.object_path("/org/mpris/MediaPlayer2/track/two")
        );
        metadata.add("{sv}", "xesam:title", new Variant.string("Second"));
        metadata.add("{sv}", "xesam:artist", new Variant.strv({ "Artist" }));
        return metadata.end();
    }

    private Variant metadata_for_track(string id) {
        var metadata = new VariantBuilder(new VariantType("a{sv}"));
        metadata.add("{sv}", "mpris:trackid", new Variant.object_path(id));
        metadata.add(
            "{sv}",
            "xesam:title",
            new Variant.string(id.has_suffix("one") ? "First" : "Second")
        );
        metadata.add("{sv}", "xesam:artist", new Variant.strv({ "Artist" }));
        return metadata.end();
    }
}

private bool layout_contains_id(Variant layout, int expected_id) {
    Variant children = layout.get_child_value(2);
    for (size_t i = 0; i < children.n_children(); i++) {
        Variant item = children.get_child_value(i).get_variant();
        if (item.get_child_value(0).get_int32() == expected_id) {
            return true;
        }
    }
    return false;
}

private int layout_index_of_id(Variant layout, int expected_id) {
    Variant children = layout.get_child_value(2);
    for (size_t i = 0; i < children.n_children(); i++) {
        Variant item = children.get_child_value(i).get_variant();
        if (item.get_child_value(0).get_int32() == expected_id) {
            return (int) i;
        }
    }
    return -1;
}

private int layout_child_id(Variant layout, int index) {
    Variant children = layout.get_child_value(2);
    return children.get_child_value(index).get_variant().get_child_value(0).get_int32();
}

private int layout_child_count(Variant layout) {
    return (int) layout.get_child_value(2).n_children();
}

private int group_property_count(Variant properties) {
    return (int) properties.n_children();
}

private Variant get_root_layout(
    MprisMiniPlayer.StatusNotifierMenu menu,
    out uint revision
) {
    Variant layout = new Variant("(ia{sv}av)", 0, null, null);
    try {
        menu.get_layout(ROOT_ID, -1, {}, out revision, out layout);
    } catch (Error error) {
        assert_not_reached();
    }
    return layout;
}

private bool get_boolean_property(
    MprisMiniPlayer.StatusNotifierMenu menu,
    int id,
    string name
) {
    try {
        return menu.get_property(id, name).get_boolean();
    } catch (Error error) {
        assert_not_reached();
    }
}

private string get_string_property(
    MprisMiniPlayer.StatusNotifierMenu menu,
    int id,
    string name
) {
    try {
        return menu.get_property(id, name).get_string();
    } catch (Error error) {
        assert_not_reached();
    }
}

private int get_int_property(
    MprisMiniPlayer.StatusNotifierMenu menu,
    int id,
    string name
) {
    try {
        return menu.get_property(id, name).get_int32();
    } catch (Error error) {
        assert_not_reached();
    }
}

private Variant get_layout(
    MprisMiniPlayer.StatusNotifierMenu menu,
    int parent_id,
    out uint revision
) {
    Variant layout = new Variant("(ia{sv}av)", 0, null, null);
    try {
        menu.get_layout(parent_id, -1, {}, out revision, out layout);
    } catch (Error error) {
        assert_not_reached();
    }
    return layout;
}

private void test_hidden_layout() {
    var menu = new MprisMiniPlayer.StatusNotifierMenu();
    uint revision;
    Variant layout = get_root_layout(menu, out revision);

    assert_true(layout_contains_id(layout, SHOW_ID));
    assert_false(layout_contains_id(layout, HIDE_ID));
    assert_true(get_boolean_property(menu, SHOW_ID, "visible"));
    assert_true(get_boolean_property(menu, SHOW_ID, "enabled"));
    assert_cmpstr(
        get_string_property(menu, SHOW_ID, "label"),
        CompareOperator.EQ,
        "Show MPRIS MiniPlayer"
    );
    assert_false(get_boolean_property(menu, HIDE_ID, "visible"));
    assert_false(get_boolean_property(menu, HIDE_ID, "enabled"));
}

private void test_shown_layout() {
    var menu = new MprisMiniPlayer.StatusNotifierMenu();
    menu.set_window_shown(true);

    uint revision;
    Variant layout = get_root_layout(menu, out revision);

    assert_false(layout_contains_id(layout, SHOW_ID));
    assert_true(layout_contains_id(layout, HIDE_ID));
    assert_false(get_boolean_property(menu, SHOW_ID, "visible"));
    assert_false(get_boolean_property(menu, SHOW_ID, "enabled"));
    assert_true(get_boolean_property(menu, HIDE_ID, "visible"));
    assert_true(get_boolean_property(menu, HIDE_ID, "enabled"));
    assert_cmpstr(
        get_string_property(menu, HIDE_ID, "label"),
        CompareOperator.EQ,
        "Hide MPRIS MiniPlayer"
    );
}

private void test_shown_state_revision() {
    var menu = new MprisMiniPlayer.StatusNotifierMenu();
    uint initial_revision;
    get_root_layout(menu, out initial_revision);

    menu.set_window_shown(true);
    uint shown_revision;
    get_root_layout(menu, out shown_revision);
    assert_true(shown_revision > initial_revision);

    menu.set_window_shown(true);
    uint unchanged_revision;
    get_root_layout(menu, out unchanged_revision);
    assert_true(unchanged_revision == shown_revision);

    menu.set_window_shown(false);
    uint hidden_revision;
    get_root_layout(menu, out hidden_revision);
    assert_true(hidden_revision > shown_revision);
}

private void test_only_current_action_activates() {
    var menu = new MprisMiniPlayer.StatusNotifierMenu();
    string action = "";
    menu.action_requested.connect((requested_action) => action = requested_action);

    try {
        menu.event(HIDE_ID, "clicked", new Variant.string(""), 0);
        assert_cmpstr(action, CompareOperator.EQ, "");
        menu.event(SHOW_ID, "clicked", new Variant.string(""), 0);
        assert_cmpstr(action, CompareOperator.EQ, "show");

        action = "";
        menu.set_window_shown(true);
        menu.event(SHOW_ID, "clicked", new Variant.string(""), 0);
        assert_cmpstr(action, CompareOperator.EQ, "");
        menu.event(HIDE_ID, "clicked", new Variant.string(""), 0);
        assert_cmpstr(action, CompareOperator.EQ, "hide");
    } catch (Error error) {
        assert_not_reached();
    }
}

private void test_status_item_uses_symbolic_icon() {
    var item = new MprisMiniPlayer.StatusNotifierItem();
    assert_cmpstr(item.icon_name, CompareOperator.EQ, SYMBOLIC_ICON_NAME);

    item.show_volume_icon(0.5);
    assert_cmpstr(
        item.icon_name,
        CompareOperator.EQ,
        "audio-volume-medium-symbolic"
    );

    item.restore_app_icon();
    assert_cmpstr(item.icon_name, CompareOperator.EQ, SYMBOLIC_ICON_NAME);
}

private void test_player_modes_and_queue_layout() {
    var transport = new StatusMenuTransport();
    var player = new MprisMiniPlayer.MprisPlayer.with_transport("test", transport);
    drain_main_context();
    var menu = new MprisMiniPlayer.StatusNotifierMenu();
    menu.set_player(player);

    uint revision;
    Variant root = get_root_layout(menu, out revision);
    assert_true(layout_contains_id(root, SHUFFLE_ID));
    assert_true(layout_contains_id(root, REPEAT_ID));
    assert_true(layout_contains_id(root, QUEUE_ID));
    assert_true(layout_index_of_id(root, QUEUE_ID) < layout_index_of_id(root, VOLUME_ID));
    assert_true(layout_index_of_id(root, VOLUME_ID) < layout_index_of_id(root, SHUFFLE_ID));
    assert_true(layout_index_of_id(root, SHUFFLE_ID) < layout_index_of_id(root, PREVIOUS_ID));
    assert_true(layout_index_of_id(root, PREVIOUS_ID) < layout_index_of_id(root, PLAY_PAUSE_ID));
    assert_true(layout_index_of_id(root, PLAY_PAUSE_ID) < layout_index_of_id(root, NEXT_ID));
    assert_true(layout_index_of_id(root, NEXT_ID) < layout_index_of_id(root, REPEAT_ID));

    Variant repeat = get_layout(menu, REPEAT_ID, out revision);
    assert_true(layout_contains_id(repeat, REPEAT_NONE_ID));
    assert_true(layout_contains_id(repeat, REPEAT_TRACK_ID));
    assert_true(layout_contains_id(repeat, REPEAT_PLAYLIST_ID));
    assert_cmpint(get_int_property(menu, REPEAT_NONE_ID, "toggle-state"), CompareOperator.EQ, 1);

    Variant queue = get_layout(menu, QUEUE_ID, out revision);
    assert_true(layout_contains_id(queue, QUEUE_TRACK_BASE_ID));
    assert_true(layout_contains_id(queue, QUEUE_TRACK_BASE_ID + 1));
    assert_cmpint(
        get_int_property(menu, QUEUE_TRACK_BASE_ID + 1, "toggle-state"),
        CompareOperator.EQ,
        1
    );
}

private void test_player_mode_actions_and_external_updates() {
    var transport = new StatusMenuTransport();
    var player = new MprisMiniPlayer.MprisPlayer.with_transport("test", transport);
    drain_main_context();
    var menu = new MprisMiniPlayer.StatusNotifierMenu();
    menu.set_player(player);
    string action = "";
    menu.action_requested.connect((requested_action) => action = requested_action);

    uint initial_revision;
    get_root_layout(menu, out initial_revision);
    try {
        menu.event(SHUFFLE_ID, "clicked", new Variant.string(""), 0);
        assert_cmpstr(action, CompareOperator.EQ, "shuffle");
        menu.event(REPEAT_TRACK_ID, "clicked", new Variant.string(""), 0);
        assert_cmpstr(action, CompareOperator.EQ, "repeat-track");
        menu.event(QUEUE_TRACK_BASE_ID, "clicked", new Variant.string(""), 0);
    } catch (Error error) {
        assert_not_reached();
    }
    assert_cmpstr(
        transport.last_go_to,
        CompareOperator.EQ,
        "/org/mpris/MediaPlayer2/track/one"
    );

    transport.emit_state(true, "Playlist");
    uint changed_revision;
    get_root_layout(menu, out changed_revision);
    assert_true(changed_revision > initial_revision);
    assert_cmpint(get_int_property(menu, SHUFFLE_ID, "toggle-state"), CompareOperator.EQ, 1);
    assert_cmpint(
        get_int_property(menu, REPEAT_PLAYLIST_ID, "toggle-state"),
        CompareOperator.EQ,
        1
    );
    assert_cmpstr(
        get_string_property(menu, REPEAT_ID, "label"),
        CompareOperator.EQ,
        "Repeat: Queue"
    );
}

private void test_stale_queue_menu_id_is_not_reused() {
    var transport = new StatusMenuTransport();
    var player = new MprisMiniPlayer.MprisPlayer.with_transport("test", transport);
    drain_main_context();
    var menu = new MprisMiniPlayer.StatusNotifierMenu();
    menu.set_player(player);

    uint revision;
    Variant initial_queue = get_layout(menu, QUEUE_ID, out revision);
    int removed_track_menu_id = layout_child_id(initial_queue, 0);

    transport.replace_queue({ "/org/mpris/MediaPlayer2/track/two" });
    drain_main_context();
    Variant updated_queue = get_layout(menu, QUEUE_ID, out revision);
    int remaining_track_menu_id = layout_child_id(updated_queue, 0);
    assert_true(remaining_track_menu_id != removed_track_menu_id);

    transport.last_go_to = "";
    try {
        menu.event(removed_track_menu_id, "clicked", new Variant.string(""), 0);
    } catch (Error error) {
        assert_not_reached();
    }
    assert_cmpstr(transport.last_go_to, CompareOperator.EQ, "");

    try {
        menu.event(remaining_track_menu_id, "clicked", new Variant.string(""), 0);
    } catch (Error error) {
        assert_not_reached();
    }
    assert_cmpstr(
        transport.last_go_to,
        CompareOperator.EQ,
        "/org/mpris/MediaPlayer2/track/two"
    );
}

private void test_unchanged_queue_preserves_menu_ids() {
    var transport = new StatusMenuTransport();
    var player = new MprisMiniPlayer.MprisPlayer.with_transport("test", transport);
    drain_main_context();
    var menu = new MprisMiniPlayer.StatusNotifierMenu();
    menu.set_player(player);

    uint initial_revision;
    Variant initial_queue = get_layout(menu, QUEUE_ID, out initial_revision);
    int first_track_menu_id = layout_child_id(initial_queue, 0);
    uint64 initial_queue_revision = player.queue_revision;

    transport.emit_state(true, "Track");
    drain_main_context();
    assert_true(player.queue_revision == initial_queue_revision);
    get_layout(menu, QUEUE_ID, out initial_revision);

    transport.replace_queue({
        "/org/mpris/MediaPlayer2/track/one",
        "/org/mpris/MediaPlayer2/track/two"
    });
    drain_main_context();
    assert_true(player.queue_revision > initial_queue_revision);

    uint updated_revision;
    Variant updated_queue = get_layout(menu, QUEUE_ID, out updated_revision);
    assert_cmpuint(updated_revision, CompareOperator.EQ, initial_revision);
    assert_cmpint(
        layout_child_id(updated_queue, 0),
        CompareOperator.EQ,
        first_track_menu_id
    );

    try {
        menu.event(
            first_track_menu_id,
            "clicked",
            new Variant.string(""),
            0
        );
    } catch (Error error) {
        assert_not_reached();
    }
    assert_cmpstr(
        transport.last_go_to,
        CompareOperator.EQ,
        "/org/mpris/MediaPlayer2/track/one"
    );
}

private void test_large_queue_layout_is_bounded() {
    var transport = new StatusMenuTransport();
    string[] track_ids = new string[145];
    for (int index = 0; index < track_ids.length; index++) {
        track_ids[index] = "/org/mpris/MediaPlayer2/track/item_%d".printf(index);
    }
    transport.track_ids = track_ids;
    var player = new MprisMiniPlayer.MprisPlayer.with_transport("test", transport);
    drain_main_context();
    var menu = new MprisMiniPlayer.StatusNotifierMenu();
    menu.set_player(player);

    uint revision;
    Variant queue = get_layout(menu, QUEUE_ID, out revision);
    assert_cmpint(layout_child_count(queue), CompareOperator.EQ, 3);
    int first_group_id = layout_child_id(queue, 0);
    Variant first_group = get_layout(menu, first_group_id, out revision);
    assert_cmpint(layout_child_count(first_group), CompareOperator.EQ, 64);
    int first_track_id = layout_child_id(first_group, 0);

    try {
        Variant properties = menu.get_group_properties({}, {});
        assert_true(group_property_count(properties) < track_ids.length);
        assert_true(group_property_count(properties) <= 64 + 32);

        Variant requested_properties = menu.get_group_properties(
            { first_track_id },
            {}
        );
        assert_cmpint(
            group_property_count(requested_properties),
            CompareOperator.EQ,
            1
        );
    } catch (Error error) {
        assert_not_reached();
    }
}

private void test_repeat_availability_updates_layout() {
    var transport = new StatusMenuTransport();
    var player = new MprisMiniPlayer.MprisPlayer.with_transport("test", transport);
    drain_main_context();
    var menu = new MprisMiniPlayer.StatusNotifierMenu();
    menu.set_player(player);

    uint initial_revision;
    Variant initial_layout = get_root_layout(menu, out initial_revision);
    assert_true(layout_contains_id(initial_layout, REPEAT_ID));

    transport.set_repeat_available(false);
    drain_main_context();
    uint updated_revision;
    Variant updated_layout = get_root_layout(menu, out updated_revision);
    assert_true(updated_revision > initial_revision);
    assert_false(layout_contains_id(updated_layout, REPEAT_ID));
}

private void test_pending_volume_updates_menu() {
    var transport = new StatusMenuTransport();
    var player = new MprisMiniPlayer.MprisPlayer.with_transport("test", transport);
    drain_main_context();
    var menu = new MprisMiniPlayer.StatusNotifierMenu();
    menu.set_player(player);
    uint before;
    get_root_layout(menu, out before);

    transport.hold_volume_write = true;
    player.set_player_volume(0.75);
    assert_true(player.volume == 0.55);
    assert_cmpstr(get_string_property(menu, VOLUME_ID, "label"), CompareOperator.EQ, "Volume: 75%");
    uint pending;
    get_root_layout(menu, out pending);
    assert_true(pending > before);

    player.toggle_mute();
    assert_cmpstr(get_string_property(menu, VOLUME_ID, "label"), CompareOperator.EQ, "Volume: 0%");
    assert_cmpstr(get_string_property(menu, MUTE_ID, "label"), CompareOperator.EQ, "Restore volume");
    transport.release_volume_write();
    drain_main_context();
    assert_true(player.volume == 0.0);
    assert_cmpstr(get_string_property(menu, VOLUME_ID, "label"), CompareOperator.EQ, "Volume: 0%");
    menu.set_player(null);
    player.shutdown();
}

private void test_metadata_separator_collision() {
    var transport = new StatusMenuTransport();
    var player = new MprisMiniPlayer.MprisPlayer.with_transport("test", transport);
    drain_main_context();
    var menu = new MprisMiniPlayer.StatusNotifierMenu();
    menu.set_player(player);
    string[] titles = { "Title\x1f" + "Artist", "Title" };
    string[] artists = { "Suffix", "Artist\x1fSuffix" };
    uint before = 0;
    for (int i = 0; i < 2; i++) {
        var metadata = new VariantBuilder(new VariantType("a{sv}"));
        metadata.add("{sv}", "xesam:title", new Variant.string(titles[i]));
        metadata.add("{sv}", "xesam:artist", new Variant.strv({ artists[i] }));
        var props = new VariantBuilder(new VariantType("a{sv}"));
        props.add("{sv}", "Metadata", metadata.end());
        transport.properties_changed(PLAYER_IFACE, props.end(), new Variant.strv({}));
        drain_main_context();
        uint revision;
        get_root_layout(menu, out revision);
        if (i == 0) before = revision;
        else assert_true(revision > before);
    }
    menu.set_player(null);
    player.shutdown();
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/status-menu/pending-volume", test_pending_volume_updates_menu);
    Test.add_func("/status-menu/metadata-separator-collision", test_metadata_separator_collision);
    Test.add_func("/status-menu/hidden-layout", test_hidden_layout);
    Test.add_func("/status-menu/shown-layout", test_shown_layout);
    Test.add_func("/status-menu/shown-state-revision", test_shown_state_revision);
    Test.add_func("/status-menu/current-action", test_only_current_action_activates);
    Test.add_func("/status-menu/player-modes-and-queue", test_player_modes_and_queue_layout);
    Test.add_func(
        "/status-menu/player-mode-actions-and-updates",
        test_player_mode_actions_and_external_updates
    );
    Test.add_func(
        "/status-menu/stale-queue-menu-id",
        test_stale_queue_menu_id_is_not_reused
    );
    Test.add_func(
        "/status-menu/unchanged-queue-preserves-menu-ids",
        test_unchanged_queue_preserves_menu_ids
    );
    Test.add_func(
        "/status-menu/large-queue-layout-is-bounded",
        test_large_queue_layout_is_bounded
    );
    Test.add_func(
        "/status-menu/repeat-availability-updates-layout",
        test_repeat_availability_updates_layout
    );
    Test.add_func("/status-item/symbolic-icon", test_status_item_uses_symbolic_icon);
    return Test.run();
}
