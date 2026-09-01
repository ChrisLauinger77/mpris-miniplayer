private const int ROOT_ID = 0;
private const int SHOW_ID = 1;
private const int HIDE_ID = 2;
private const string SYMBOLIC_ICON_NAME =
    "io.github.ChrisLauinger.MprisMiniPlayer-symbolic";

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

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/status-menu/hidden-layout", test_hidden_layout);
    Test.add_func("/status-menu/shown-layout", test_shown_layout);
    Test.add_func("/status-menu/shown-state-revision", test_shown_state_revision);
    Test.add_func("/status-menu/current-action", test_only_current_action_activates);
    Test.add_func("/status-item/symbolic-icon", test_status_item_uses_symbolic_icon);
    return Test.run();
}
