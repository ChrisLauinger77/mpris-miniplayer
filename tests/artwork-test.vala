[CCode (cname = "test_live_decoders")]
extern int live_decoders();

private const string BROKEN_ART = "data:image/jpeg;base64,/9j/AA==";

private void drain() {
    while (MainContext.default().pending()) MainContext.default().iteration(false);
}

private void test_decoder_failure_releases_loader() {
    var artwork = new MprisMiniPlayer.ArtworkLoader();
    var bytes = new Bytes(new uint8[] { 0xff, 0xd8, 0xff, 0 });
    for (int i = 0; i < 100; i++) {
        try {
            artwork.decode_artwork(bytes);
            assert_not_reached();
        } catch (Error error) {
            assert_true(error is IOError.FAILED);
            assert_cmpstr(error.message, CompareOperator.EQ, "Injected decoder failure");
        }
        assert_cmpint(live_decoders(), CompareOperator.EQ, 0);
    }
    artwork.shutdown();
}

private void test_source_identity_and_shutdown() {
    var artwork = new MprisMiniPlayer.ArtworkLoader();
    int failures = 0;
    artwork.failed.connect(() => failures++);
    artwork.set_source("player-a/track-a", BROKEN_ART);
    assert_cmpint(failures, CompareOperator.EQ, 1);
    artwork.set_source("player-a/track-a", BROKEN_ART);
    assert_cmpint(failures, CompareOperator.EQ, 1);
    artwork.set_source("player-b/track-a", BROKEN_ART);
    assert_cmpint(failures, CompareOperator.EQ, 2);
    artwork.set_source("player-b/track-b", BROKEN_ART);
    assert_cmpint(failures, CompareOperator.EQ, 3);
    artwork.shutdown();
    artwork.shutdown();
    var weak_artwork = WeakRef(artwork);
    artwork = null;
    drain();
    assert_null(weak_artwork.get());
    assert_cmpint(live_decoders(), CompareOperator.EQ, 0);
}

private void test_reentrant_failure_cannot_schedule_old_retry() {
    var artwork = new MprisMiniPlayer.ArtworkLoader();
    // Keep the signal's callback target weak, as the UI does.
    ulong handler = artwork.failed.connect(() => artwork.shutdown());
    artwork.set_source("track", BROKEN_ART);
    SignalHandler.disconnect(artwork, handler);
    var weak_artwork = WeakRef(artwork);
    artwork = null;
    drain();
    assert_null(weak_artwork.get());
}

private delegate bool Condition();
private void wait_until(Condition condition, uint timeout_ms = 10000) {
    bool expired = false;
    uint timeout = Timeout.add(timeout_ms, () => { expired = true; return Source.REMOVE; });
    while (!condition() && !expired) MainContext.default().iteration(true);
    if (!expired) Source.remove(timeout);
    assert_false(expired);
}

private void test_bounded_retries_and_explicit_retry() {
    var artwork = new MprisMiniPlayer.ArtworkLoader();
    int failures = 0;
    artwork.failed.connect(() => failures++);
    artwork.set_source("track", BROKEN_ART);
    wait_until(() => failures == 3);
    drain();
    artwork.retry();
    assert_cmpint(failures, CompareOperator.EQ, 4);
    artwork.shutdown();
    var weak_artwork = WeakRef(artwork);
    artwork = null;
    drain();
    assert_null(weak_artwork.get());
}

private void test_cancel_pending_file_read() {
    try {
        string directory = DirUtils.make_tmp("mpris-artwork-test-XXXXXX");
        string path = Path.build_filename(directory, "cover.jpg");
        FileUtils.set_contents(path, "unused file contents");
        var artwork = new MprisMiniPlayer.ArtworkLoader();
        int failures = 0;
        artwork.failed.connect(() => failures++);
        artwork.set_source("old track", File.new_for_path(path).get_uri());
        artwork.set_source("new track", BROKEN_ART);
        assert_cmpint(failures, CompareOperator.EQ, 1);
        artwork.shutdown();
        var weak_artwork = WeakRef(artwork);
        artwork = null;
        wait_until(() => weak_artwork.get() == null);
        assert_cmpint(failures, CompareOperator.EQ, 1);
        File.new_for_path(path).delete();
        File.new_for_path(directory).delete();
    } catch (Error error) {
        Test.fail_printf("Artwork file fixture: %s", error.message);
    }
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/artwork/bounded-retry", test_bounded_retries_and_explicit_retry);
    Test.add_func("/artwork/cancel-file-read", test_cancel_pending_file_read);
    Test.add_func("/artwork/decoder-failure-lifetime", test_decoder_failure_releases_loader);
    Test.add_func("/artwork/source-identity-shutdown", test_source_identity_and_shutdown);
    Test.add_func("/artwork/reentrant-failure", test_reentrant_failure_cannot_schedule_old_retry);
    return Test.run();
}
