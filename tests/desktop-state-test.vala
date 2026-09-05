private void test_autostart_file_state() {
    try {
        string directory = DirUtils.make_tmp("mpris-autostart-test-XXXXXX");
        string path = Path.build_filename(directory, "test.desktop");
        assert_false(MprisMiniPlayer.Autostart.read_enabled(path));
        string entry = "[Desktop Entry]\nType=Application\nExec=mpris-miniplayer\n";
        FileUtils.set_contents(path, entry);
        assert_true(MprisMiniPlayer.Autostart.read_enabled(path));
        FileUtils.set_contents(path, entry + "Hidden=true\n");
        assert_false(MprisMiniPlayer.Autostart.read_enabled(path));
        FileUtils.set_contents(path, entry + "X-GNOME-Autostart-enabled=false\n");
        assert_false(MprisMiniPlayer.Autostart.read_enabled(path));
        FileUtils.set_contents(path, "invalid file");
        assert_false(MprisMiniPlayer.Autostart.read_enabled(path));
        // Deletion failures must propagate, rather than claiming success.
        try {
            MprisMiniPlayer.Autostart.remove_entry(directory);
            assert_not_reached();
        } catch (IOError.NOT_EMPTY error) {}
        assert_true(MprisMiniPlayer.Autostart.remove_entry(path));
        assert_true(MprisMiniPlayer.Autostart.remove_entry(path));
        File.new_for_path(directory).delete();
    } catch (Error error) {
        Test.fail_printf("Autostart fixture: %s", error.message);
    }
}

private void test_portal_results_are_typed() {
    var values = new VariantBuilder(new VariantType("a{sv}"));
    values.add("{sv}", "background", new Variant.boolean(false));
    values.add("{sv}", "autostart", new Variant.string("true"));
    Variant results = values.end();
    assert_false(MprisMiniPlayer.BackgroundPortal.response_flag(results, "background"));
    assert_false(MprisMiniPlayer.BackgroundPortal.response_flag(results, "autostart"));
    assert_false(MprisMiniPlayer.BackgroundPortal.response_flag(results, "missing"));
    values = new VariantBuilder(new VariantType("a{sv}"));
    values.add("{sv}", "autostart", new Variant.boolean(true));
    assert_true(MprisMiniPlayer.BackgroundPortal.response_flag(values.end(), "autostart"));
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/desktop/autostart-state", test_autostart_file_state);
    Test.add_func("/desktop/portal-typed-result", test_portal_results_are_typed);
    return Test.run();
}
