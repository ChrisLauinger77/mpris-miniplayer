private void assert_newer(string candidate, string current, bool expected) {
    bool actual = MprisMiniPlayer.UpdateChecker.is_newer_version(candidate, current);
    assert_true(actual == expected);
}

private string next_patch_version() {
    string[] parts = MprisMiniPlayer.Config.VERSION.split(".");
    int patch = 0;
    assert_true(parts.length == 3);
    assert_true(int.try_parse(parts[2], out patch));
    return "%s.%s.%d".printf(parts[0], parts[1], patch + 1);
}

private void test_version_comparison() {
    assert_newer("1.3.9", "1.4.0", false);
    assert_newer("1.4.0", "1.4.0", false);
    assert_newer("1.4.1", "1.4.0", true);
    assert_newer("1.5.0", "1.4.9", true);
    assert_newer("2.0.0", "1.99.99", true);
    assert_newer("v1.4.1", "1.4.0", true);
    assert_newer("1.4", "1.4.0", false);
    assert_newer("1.4.0-beta", "1.4.0", false);
    assert_newer("latest", "1.4.0", false);
}

private void test_release_uri() {
    var checker = new MprisMiniPlayer.UpdateChecker();
    string found_version = "";
    string found_url = "";
    string newer_version = next_patch_version();
    string newer_url =
        "https://github.com/ChrisLauinger77/mpris-miniplayer/releases/tag/v%s".printf(
            newer_version
        );
    checker.update_available.connect((version, release_url) => {
        found_version = version;
        found_url = release_url;
    });

    try {
        checker.process_release_uri(Uri.parse(newer_url, UriFlags.NONE));
    } catch (Error error) {
        assert_not_reached();
    }

    assert_cmpstr(found_version, CompareOperator.EQ, newer_version);
    assert_cmpstr(found_url, CompareOperator.EQ, newer_url);
}

private void test_current_release_uri() {
    var checker = new MprisMiniPlayer.UpdateChecker();
    bool emitted = false;
    checker.update_available.connect(() => emitted = true);

    try {
        checker.process_release_uri(Uri.parse(
            "https://github.com/ChrisLauinger77/mpris-miniplayer/releases/tag/v%s".printf(
                MprisMiniPlayer.Config.VERSION
            ),
            UriFlags.NONE
        ));
    } catch (Error error) {
        assert_not_reached();
    }

    assert_false(emitted);
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/update-checker/version-comparison", test_version_comparison);
    Test.add_func("/update-checker/release-uri", test_release_uri);
    Test.add_func("/update-checker/current-release-uri", test_current_release_uri);
    return Test.run();
}
