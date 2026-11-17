private const string SCHEMA_ID = "io.github.ChrisLauinger.MprisMiniPlayer";

private SettingsSchema load_schema(string directory, string id) throws Error {
    var source = new SettingsSchemaSource.from_directory(directory, null, false);
    var schema = source.lookup(id, false);
    assert_nonnull(schema);
    return schema;
}

private void assert_ids(string[] actual, string[] expected) {
    assert_true(new Variant.strv(actual).equal(new Variant.strv(expected)));
}

private Variant player_details() {
    var details = new VariantBuilder(new VariantType("a{s(ss)}"));
    details.add("{s(ss)}", "vlc", "VLC media player", "vlc");
    return details.end();
}

private void check_details_fallback(Settings? settings) {
    var app_settings = new MprisMiniPlayer.AppSettings.with_settings(settings);
    int changes = 0;
    app_settings.changed.connect((key) => {
        assert_cmpstr(key, CompareOperator.EQ, "blacklisted-player-details");
        changes++;
    });
    assert_cmpuint((uint) app_settings.blacklisted_player_details.n_children(), CompareOperator.EQ, 0);
    app_settings.blacklisted_player_details = player_details();
    assert_true(app_settings.blacklisted_player_details.equal(player_details()));
    app_settings.blacklisted_player_details = player_details();
    assert_cmpint(changes, CompareOperator.EQ, 1);
}

private void check_fallback(Settings? settings) {
    var app_settings = new MprisMiniPlayer.AppSettings.with_settings(settings);
    int changes = 0;
    app_settings.changed.connect((key) => {
        assert_cmpstr(key, CompareOperator.EQ, "blacklisted-players");
        changes++;
    });
    assert_ids(app_settings.blacklisted_players, {});
    app_settings.blacklisted_players = { "vlc", "firefox" };
    assert_ids(app_settings.blacklisted_players, { "vlc", "firefox" });
    app_settings.blacklisted_players = { "vlc", "firefox" };
    assert_cmpint(changes, CompareOperator.EQ, 1);
    // Callers must not be able to mutate the stored fallback through a getter.
    var copy = app_settings.blacklisted_players;
    copy[0] = "other";
    assert_ids(app_settings.blacklisted_players, { "vlc", "firefox" });
    app_settings.blacklisted_players = {};
    assert_ids(app_settings.blacklisted_players, {});
    assert_cmpint(changes, CompareOperator.EQ, 2);
}

private void test_no_schema() {
    check_fallback(null);
    check_details_fallback(null);
}

private void test_old_schema() {
    try {
        var schema = load_schema(Environment.get_variable("TEST_LEGACY_SCHEMA_DIR"), SCHEMA_ID + ".LegacyTest");
        var settings = new Settings.full(schema, SettingsBackend.memory_settings_backend_new(), null);
        check_fallback(settings);
        check_details_fallback(settings);
    } catch (Error error) {
        Test.fail_printf("Legacy schema: %s", error.message);
    }
}

private void test_external_changes() {
    try {
        var schema = load_schema(Environment.get_variable("TEST_APP_SCHEMA_DIR"), SCHEMA_ID);
        var backend = SettingsBackend.memory_settings_backend_new();
        var settings = new Settings.full(schema, backend, null);
        var external = new Settings.full(schema, backend, null);
        var app_settings = new MprisMiniPlayer.AppSettings.with_settings(settings);
        int changes = 0;
        app_settings.changed.connect((key) => {
            assert_cmpstr(key, CompareOperator.EQ, "blacklisted-players");
            changes++;
        });
        assert_ids(app_settings.blacklisted_players, {});
        external.set_strv("blacklisted-players", { "vlc" });
        assert_ids(app_settings.blacklisted_players, { "vlc" });
        app_settings.blacklisted_players = { "firefox", "mpv" };
        assert_ids(external.get_strv("blacklisted-players"), { "firefox", "mpv" });
        external.reset("blacklisted-players");
        assert_ids(app_settings.blacklisted_players, {});
        assert_cmpint(changes, CompareOperator.EQ, 3);
    } catch (Error error) {
        Test.fail_printf("External settings: %s", error.message);
    }
}

private void test_persistence() {
    try {
        string directory = DirUtils.make_tmp("mpris-blacklist-settings-XXXXXX");
        string path = Path.build_filename(directory, "settings.ini");
        var schema = load_schema(Environment.get_variable("TEST_APP_SCHEMA_DIR"), SCHEMA_ID);
        var settings = new Settings.full(schema, SettingsBackend.keyfile_settings_backend_new(path, "/", null), null);
        var app_settings = new MprisMiniPlayer.AppSettings.with_settings(settings);
        app_settings.blacklisted_players = { "vlc", "io.bassi.Amberol" };
        app_settings.blacklisted_player_details = player_details();
        Settings.sync();
        var restored = new MprisMiniPlayer.AppSettings.with_settings(new Settings.full(schema,
            SettingsBackend.keyfile_settings_backend_new(path, "/", null), null));
        assert_ids(restored.blacklisted_players, { "vlc", "io.bassi.Amberol" });
        assert_true(restored.blacklisted_player_details.equal(player_details()));
        File.new_for_path(path).delete();
        File.new_for_path(directory).delete();
    } catch (Error error) {
        Test.fail_printf("Settings persistence: %s", error.message);
    }
}

private void test_external_details() {
    try {
        var schema = load_schema(Environment.get_variable("TEST_APP_SCHEMA_DIR"), SCHEMA_ID);
        var backend = SettingsBackend.memory_settings_backend_new();
        var settings = new Settings.full(schema, backend, null);
        var external = new Settings.full(schema, backend, null);
        var app_settings = new MprisMiniPlayer.AppSettings.with_settings(settings);
        int changes = 0;
        app_settings.changed.connect((key) => {
            assert_cmpstr(key, CompareOperator.EQ, "blacklisted-player-details");
            changes++;
        });
        external.set_value("blacklisted-player-details", player_details());
        assert_true(app_settings.blacklisted_player_details.equal(player_details()));
        external.reset("blacklisted-player-details");
        assert_cmpuint((uint) app_settings.blacklisted_player_details.n_children(), CompareOperator.EQ, 0);
        assert_cmpint(changes, CompareOperator.EQ, 2);
    } catch (Error error) {
        Test.fail_printf("External player details: %s", error.message);
    }
}

private void check_queued_ignore_changes(Settings? settings) {
    var app_settings = new MprisMiniPlayer.AppSettings.with_settings(settings);
    app_settings.blacklisted_players = { "vlc" };
    int changes = 0;
    app_settings.changed.connect((key) => {
        assert_cmpstr(key, CompareOperator.EQ, "blacklisted-players");
        changes++;
    });
    app_settings.queue_player_ignored("firefox", true);
    app_settings.queue_player_ignored("vlc", false);
    app_settings.queue_player_ignored("mpv", true);
    app_settings.queue_player_ignored("mpv", false);
    // Nothing is written while the caller's signal emission is still running.
    assert_ids(app_settings.blacklisted_players, { "vlc" });
    assert_cmpint(changes, CompareOperator.EQ, 0);
    while (MainContext.default().iteration(false)) {}
    // Toggles apply in order and coalesce into one write.
    assert_ids(app_settings.blacklisted_players, { "firefox" });
    assert_cmpint(changes, CompareOperator.EQ, 1);

    app_settings.queue_player_ignored("firefox", false);
    app_settings.queue_player_ignored("firefox", true);
    while (MainContext.default().iteration(false)) {}
    assert_ids(app_settings.blacklisted_players, { "firefox" });
    assert_cmpint(changes, CompareOperator.EQ, 1);
}

private void test_queued_ignore_changes() {
    check_queued_ignore_changes(null);
    try {
        var schema = load_schema(Environment.get_variable("TEST_APP_SCHEMA_DIR"), SCHEMA_ID);
        check_queued_ignore_changes(new Settings.full(schema, SettingsBackend.memory_settings_backend_new(), null));
    } catch (Error error) {
        Test.fail_printf("Queued ignore changes: %s", error.message);
    }
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/blacklist-settings/queued-ignore-changes", test_queued_ignore_changes);
    Test.add_func("/blacklist-settings/no-schema", test_no_schema);
    Test.add_func("/blacklist-settings/old-schema", test_old_schema);
    Test.add_func("/blacklist-settings/external-changes", test_external_changes);
    Test.add_func("/blacklist-settings/persistence", test_persistence);
    Test.add_func("/blacklist-settings/external-details", test_external_details);
    return Test.run();
}
