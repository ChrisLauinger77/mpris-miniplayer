namespace MprisMiniPlayer {
    [DBus (name = "org.kde.StatusNotifierWatcher")]
    private interface StatusNotifierWatcher : Object {
        public abstract void RegisterStatusNotifierItem(string service) throws DBusError, IOError;
    }

    [DBus (name = "org.kde.StatusNotifierItem")]
    public class StatusNotifierItem : Object {
        private const string APP_ID = "io.github.ChrisLauinger.MprisMiniPlayer";
        private const string SYMBOLIC_ICON_NAME = APP_ID + "-symbolic";
        private const string MENU_OBJECT_PATH = "/StatusNotifierMenu";
        private string displayed_icon_name = SYMBOLIC_ICON_NAME;

        public signal void activated();
        public signal void scroll_requested(int delta, string orientation);

        [DBus (name = "NewIcon")]
        public signal void new_icon();

        [DBus (name = "NewTitle")]
        public signal void new_title();

        [DBus (name = "Category")]
        public string category {
            owned get {
                return "ApplicationStatus";
            }
        }

        [DBus (name = "Id")]
        public string id {
            owned get {
                return APP_ID;
            }
        }

        [DBus (name = "Title")]
        public string title {
            owned get {
                return _("MPRIS MiniPlayer");
            }
        }

        [DBus (name = "Status")]
        public string status {
            owned get {
                return "Active";
            }
        }

        [DBus (name = "IconName")]
        public string icon_name {
            owned get {
                return displayed_icon_name;
            }
        }

        [DBus (name = "ItemIsMenu")]
        public bool item_is_menu {
            get {
                return false;
            }
        }

        [DBus (name = "Menu")]
        public ObjectPath menu {
            owned get {
                return new ObjectPath(MENU_OBJECT_PATH);
            }
        }

        [DBus (name = "WindowId")]
        public uint32 window_id {
            get {
                return 0;
            }
        }

        [DBus (name = "OverlayIconName")]
        public string overlay_icon_name {
            owned get {
                return "";
            }
        }

        [DBus (name = "AttentionIconName")]
        public string attention_icon_name {
            owned get {
                return "";
            }
        }

        [DBus (name = "AttentionMovieName")]
        public string attention_movie_name {
            owned get {
                return "";
            }
        }

        [DBus (name = "Activate")]
        public void activate(int x, int y) throws DBusError, IOError {
            activated();
        }

        [DBus (name = "ContextMenu")]
        public void context_menu(int x, int y) throws DBusError, IOError {
        }

        [DBus (name = "SecondaryActivate")]
        public void secondary_activate(int x, int y) throws DBusError, IOError {
            activated();
        }

        [DBus (name = "Scroll")]
        public void scroll(int delta, string orientation) throws DBusError, IOError {
            scroll_requested(delta, orientation);
        }

        [DBus (visible = false)]
        public void show_volume_icon(double volume) {
            if (volume <= 0.0) {
                displayed_icon_name = "audio-volume-muted-symbolic";
            } else if (volume < 0.35) {
                displayed_icon_name = "audio-volume-low-symbolic";
            } else if (volume < 0.70) {
                displayed_icon_name = "audio-volume-medium-symbolic";
            } else {
                displayed_icon_name = "audio-volume-high-symbolic";
            }
            new_icon();
        }

        [DBus (visible = false)]
        public void restore_app_icon() {
            if (displayed_icon_name == SYMBOLIC_ICON_NAME) {
                return;
            }

            displayed_icon_name = SYMBOLIC_ICON_NAME;
            new_icon();
        }
    }

    [DBus (name = "com.canonical.dbusmenu")]
    public class StatusNotifierMenu : Object {
        private const int ROOT_ID = 0;
        private const int SHOW_ID = 1;
        private const int HIDE_ID = 2;
        private const int COMPACT_MODE_ID = 3;
        private const int PREFERENCES_ID = 4;
        private const int ABOUT_ID = 5;
        private const int QUIT_ID = 6;
        private const int MEDIA_SEPARATOR_ID = 7;
        private const int SETTINGS_SEPARATOR_ID = 8;
        private const int UPDATE_ID = 9;
        private const int TITLE_ID = 10;
        private const int ARTIST_ID = 11;
        private const int ALBUM_ID = 12;
        private const int NO_PLAYER_ID = 13;
        private const int CONTROLS_SEPARATOR_ID = 14;
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
        private const int VOLUME_25_ID = 32;
        private const int VOLUME_50_ID = 33;
        private const int VOLUME_75_ID = 34;
        private const int VOLUME_100_ID = 35;
        private const int QUEUE_ID = 40;
        private const int QUEUE_EMPTY_ID = 41;
        private const int QUEUE_TRACK_BASE_ID = 1000;

        private uint revision = 1;
        private bool compact_mode = false;
        private bool window_shown = false;
        private MprisPlayer? player;
        private ulong player_changed_handler_id = 0;
        private string player_state_signature = "none";
        private string update_version = "";

        public signal void action_requested(string action);

        [DBus (name = "ItemsPropertiesUpdated")]
        public signal void items_properties_updated(Variant updated_props, Variant removed_props);

        [DBus (name = "LayoutUpdated")]
        public signal void layout_updated(uint revision, int parent);

        [DBus (name = "ItemActivationRequested")]
        public signal void item_activation_requested(int id, uint timestamp);

        [DBus (name = "Version")]
        public uint version {
            get {
                return 3;
            }
        }

        [DBus (name = "TextDirection")]
        public string text_direction {
            owned get {
                return "ltr";
            }
        }

        [DBus (name = "Status")]
        public string status {
            owned get {
                return "normal";
            }
        }

        [DBus (name = "IconThemePath")]
        public string[] icon_theme_path {
            owned get {
                return {};
            }
        }

        [DBus (visible = false)]
        public void set_compact_mode(bool enabled) {
            if (compact_mode == enabled) {
                return;
            }

            compact_mode = enabled;
            notify_layout_changed();
        }

        [DBus (visible = false)]
        public void set_window_shown(bool shown) {
            if (window_shown == shown) {
                return;
            }

            window_shown = shown;
            notify_layout_changed();
        }

        [DBus (visible = false)]
        public void set_player(MprisPlayer? selected_player) {
            if (player == selected_player) {
                return;
            }

            if (player != null && player_changed_handler_id != 0) {
                SignalHandler.disconnect(player, player_changed_handler_id);
                player_changed_handler_id = 0;
            }

            player = selected_player;
            if (player != null) {
                player_changed_handler_id = player.changed.connect(on_player_changed);
            }
            player_state_signature = build_player_state_signature();
            notify_layout_changed();
        }

        [DBus (visible = false)]
        public void set_update_available(string version) {
            if (update_version == version) {
                return;
            }

            update_version = version;
            notify_layout_changed();
        }

        [DBus (name = "GetLayout")]
        public void get_layout(
            int parent_id,
            int recursion_depth,
            string[] property_names,
            out uint revision,
            [DBus (signature = "(ia{sv}av)")]
            out Variant layout
        ) throws DBusError, IOError {
            revision = this.revision;
            if (parent_id == VOLUME_ID) {
                layout = build_volume_item(recursion_depth);
            } else if (parent_id == REPEAT_ID) {
                layout = build_repeat_item(recursion_depth);
            } else if (parent_id == QUEUE_ID) {
                layout = build_queue_item(recursion_depth);
            } else if (parent_id == ROOT_ID) {
                layout = build_layout(recursion_depth);
            } else {
                layout = build_item(parent_id);
            }
        }

        [DBus (name = "GetGroupProperties", signature = "a(ia{sv})")]
        public Variant get_group_properties(int[] ids, string[] property_names) throws DBusError, IOError {
            var items = new VariantBuilder(new VariantType("a(ia{sv})"));
            int[] requested_ids = ids.length == 0 ? all_ids() : ids;

            foreach (int id in requested_ids) {
                if (is_known_id(id)) {
                    items.add_value(new Variant.tuple({
                        new Variant.int32(id),
                        build_properties(id)
                    }));
                }
            }

            return items.end();
        }

        [DBus (name = "GetProperty")]
        public new Variant get_property(int id, string name) throws DBusError, IOError {
            Variant? value = build_properties(id).lookup_value(name, null);
            if (value != null) {
                return value;
            }

            return new Variant.string("");
        }

        [DBus (name = "Event")]
        public void event(int id, string event_id, Variant data, uint timestamp) throws DBusError, IOError {
            if (event_id == "clicked" && is_enabled(id)) {
                activate_item(id);
            }
        }

        [DBus (name = "AboutToShow")]
        public bool about_to_show(int id) throws DBusError, IOError {
            return false;
        }

        [DBus (name = "AboutToShowGroup")]
        public void about_to_show_group(
            int[] ids,
            out int[] updates_needed,
            out int[] id_errors
        ) throws DBusError, IOError {
            updates_needed = {};
            id_errors = {};
        }

        private Variant build_layout(int recursion_depth = -1) {
            var children = new VariantBuilder(new VariantType("av"));
            if (recursion_depth != 0) {
                children.add_value(new Variant.variant(
                    build_item(window_shown ? HIDE_ID : SHOW_ID)
                ));
                children.add_value(new Variant.variant(build_item(MEDIA_SEPARATOR_ID)));

                if (player == null) {
                    children.add_value(new Variant.variant(build_item(NO_PLAYER_ID)));
                } else {
                    children.add_value(new Variant.variant(build_item(TITLE_ID)));
                    children.add_value(new Variant.variant(build_item(ARTIST_ID)));
                    if (player.album != "") {
                        children.add_value(new Variant.variant(build_item(ALBUM_ID)));
                    }
                    children.add_value(new Variant.variant(build_item(CONTROLS_SEPARATOR_ID)));
                    if (player.has_track_list) {
                        children.add_value(new Variant.variant(
                            build_queue_item(recursion_depth - 1)
                        ));
                    }
                    if (player.has_volume) {
                        children.add_value(new Variant.variant(
                            build_volume_item(recursion_depth - 1)
                        ));
                    }
                    if (player.has_shuffle) {
                        children.add_value(new Variant.variant(build_item(SHUFFLE_ID)));
                    }
                    children.add_value(new Variant.variant(build_item(PREVIOUS_ID)));
                    children.add_value(new Variant.variant(build_item(PLAY_PAUSE_ID)));
                    children.add_value(new Variant.variant(build_item(NEXT_ID)));
                    if (player.has_loop_status) {
                        children.add_value(new Variant.variant(
                            build_repeat_item(recursion_depth - 1)
                        ));
                    }
                }

                children.add_value(new Variant.variant(build_item(SETTINGS_SEPARATOR_ID)));
                children.add_value(new Variant.variant(build_item(COMPACT_MODE_ID)));
                if (update_version != "") {
                    children.add_value(new Variant.variant(build_item(UPDATE_ID)));
                }
                children.add_value(new Variant.variant(build_item(PREFERENCES_ID)));
                children.add_value(new Variant.variant(build_item(ABOUT_ID)));
                children.add_value(new Variant.variant(build_item(QUIT_ID)));
            }

            var root_properties = new VariantBuilder(new VariantType("a{sv}"));
            root_properties.add("{sv}", "children-display", new Variant.string("submenu"));

            return new Variant.tuple({
                new Variant.int32(ROOT_ID),
                root_properties.end(),
                children.end()
            });
        }

        private Variant build_item(int id) {
            var children = new VariantBuilder(new VariantType("av"));
            return new Variant.tuple({
                new Variant.int32(id),
                build_properties(id),
                children.end()
            });
        }

        private Variant build_volume_item(int recursion_depth = -1) {
            var children = new VariantBuilder(new VariantType("av"));
            if (recursion_depth != 0) {
                children.add_value(new Variant.variant(build_item(MUTE_ID)));
                children.add_value(new Variant.variant(build_item(VOLUME_25_ID)));
                children.add_value(new Variant.variant(build_item(VOLUME_50_ID)));
                children.add_value(new Variant.variant(build_item(VOLUME_75_ID)));
                children.add_value(new Variant.variant(build_item(VOLUME_100_ID)));
            }

            return new Variant.tuple({
                new Variant.int32(VOLUME_ID),
                build_properties(VOLUME_ID),
                children.end()
            });
        }

        private Variant build_repeat_item(int recursion_depth = -1) {
            var children = new VariantBuilder(new VariantType("av"));
            if (recursion_depth != 0) {
                children.add_value(new Variant.variant(build_item(REPEAT_NONE_ID)));
                children.add_value(new Variant.variant(build_item(REPEAT_TRACK_ID)));
                children.add_value(new Variant.variant(build_item(REPEAT_PLAYLIST_ID)));
            }

            return new Variant.tuple({
                new Variant.int32(REPEAT_ID),
                build_properties(REPEAT_ID),
                children.end()
            });
        }

        private Variant build_queue_item(int recursion_depth = -1) {
            var children = new VariantBuilder(new VariantType("av"));
            if (recursion_depth != 0 && player != null) {
                if (player.queue.length == 0) {
                    children.add_value(new Variant.variant(build_item(QUEUE_EMPTY_ID)));
                } else {
                    for (int index = 0; index < player.queue.length; index++) {
                        children.add_value(new Variant.variant(
                            build_item(QUEUE_TRACK_BASE_ID + index)
                        ));
                    }
                }
            }

            return new Variant.tuple({
                new Variant.int32(QUEUE_ID),
                build_properties(QUEUE_ID),
                children.end()
            });
        }

        private Variant build_properties(int id) {
            var properties = new VariantBuilder(new VariantType("a{sv}"));
            if (is_separator(id)) {
                properties.add("{sv}", "type", new Variant.string("separator"));
                properties.add("{sv}", "visible", new Variant.boolean(true));
                return properties.end();
            }

            properties.add("{sv}", "enabled", new Variant.boolean(is_enabled(id)));
            properties.add(
                "{sv}",
                "visible",
                new Variant.boolean(is_visible(id))
            );
            properties.add("{sv}", "type", new Variant.string("standard"));
            properties.add("{sv}", "label", new Variant.string(get_label(id)));
            string icon_name = get_icon_name(id);
            if (icon_name != "") {
                properties.add("{sv}", "icon-name", new Variant.string(icon_name));
            }
            if (id == COMPACT_MODE_ID || id == SHUFFLE_ID) {
                properties.add("{sv}", "toggle-type", new Variant.string("checkmark"));
                bool toggled = id == COMPACT_MODE_ID
                    ? compact_mode
                    : player != null && player.shuffle;
                properties.add("{sv}", "toggle-state", new Variant.int32(toggled ? 1 : 0));
            }
            if (is_volume_preset(id) || is_repeat_mode(id) || is_queue_track(id)) {
                properties.add("{sv}", "toggle-type", new Variant.string("radio"));
                properties.add(
                    "{sv}",
                    "toggle-state",
                    new Variant.int32(item_is_selected(id) ? 1 : 0)
                );
            }
            if (id == VOLUME_ID || id == REPEAT_ID || id == QUEUE_ID) {
                properties.add("{sv}", "children-display", new Variant.string("submenu"));
            }
            return properties.end();
        }

        private string get_label(int id) {
            switch (id) {
                case SHOW_ID:
                    return _("Show MPRIS MiniPlayer");
                case HIDE_ID:
                    return _("Hide MPRIS MiniPlayer");
                case UPDATE_ID:
                    return _("Update available: %s").printf(update_version);
                case TITLE_ID:
                    return truncate_label(player != null ? player.title : "", 30);
                case ARTIST_ID:
                    return truncate_label(player != null ? player.artist : "", 30);
                case ALBUM_ID:
                    return escape_label(player != null ? player.album : "");
                case NO_PLAYER_ID:
                    return _("No player detected");
                case PREVIOUS_ID:
                    return _("Previous");
                case PLAY_PAUSE_ID:
                    return player != null && player.playback_status == "Playing"
                        ? _("Pause")
                        : _("Play");
                case NEXT_ID:
                    return _("Next");
                case SHUFFLE_ID:
                    return _("Shuffle");
                case REPEAT_ID:
                    return repeat_label();
                case REPEAT_NONE_ID:
                    return _("Off");
                case REPEAT_TRACK_ID:
                    return _("Current Track");
                case REPEAT_PLAYLIST_ID:
                    return _("Queue");
                case QUEUE_ID:
                    return _("Queue");
                case QUEUE_EMPTY_ID:
                    return _("Queue is empty");
                case VOLUME_ID:
                    return _("Volume: %d%%").printf(current_volume_percent());
                case MUTE_ID:
                    return player != null && player.volume > 0.0
                        ? _("Mute")
                        : _("Restore volume");
                case VOLUME_25_ID:
                    return "25%";
                case VOLUME_50_ID:
                    return "50%";
                case VOLUME_75_ID:
                    return "75%";
                case VOLUME_100_ID:
                    return "100%";
                case COMPACT_MODE_ID:
                    return _("Compact Mode");
                case PREFERENCES_ID:
                    return _("Preferences");
                case ABOUT_ID:
                    return _("About");
                case QUIT_ID:
                    return _("Quit");
                default:
                    return is_queue_track(id) ? queue_track_label(id) : "";
            }
        }

        private void activate_item(int id) {
            if (is_queue_track(id)) {
                int index = id - QUEUE_TRACK_BASE_ID;
                if (player != null && index >= 0 && index < player.queue.length) {
                    player.go_to(player.queue[index].id);
                }
                return;
            }

            switch (id) {
                case SHOW_ID:
                    action_requested("show");
                    break;
                case HIDE_ID:
                    action_requested("hide");
                    break;
                case UPDATE_ID:
                    action_requested("open-release");
                    break;
                case PREVIOUS_ID:
                    action_requested("previous");
                    break;
                case PLAY_PAUSE_ID:
                    action_requested("play-pause");
                    break;
                case NEXT_ID:
                    action_requested("next");
                    break;
                case SHUFFLE_ID:
                    action_requested("shuffle");
                    break;
                case REPEAT_NONE_ID:
                    action_requested("repeat-none");
                    break;
                case REPEAT_TRACK_ID:
                    action_requested("repeat-track");
                    break;
                case REPEAT_PLAYLIST_ID:
                    action_requested("repeat-playlist");
                    break;
                case MUTE_ID:
                    action_requested("mute");
                    break;
                case VOLUME_25_ID:
                    action_requested("volume-25");
                    break;
                case VOLUME_50_ID:
                    action_requested("volume-50");
                    break;
                case VOLUME_75_ID:
                    action_requested("volume-75");
                    break;
                case VOLUME_100_ID:
                    action_requested("volume-100");
                    break;
                case COMPACT_MODE_ID:
                    action_requested("compact-mode");
                    break;
                case PREFERENCES_ID:
                    action_requested("preferences");
                    break;
                case ABOUT_ID:
                    action_requested("about");
                    break;
                case QUIT_ID:
                    action_requested("quit");
                    break;
                default:
                    return;
            }
        }

        private void notify_layout_changed() {
            revision++;
            layout_updated(revision, ROOT_ID);
        }

        private void on_player_changed() {
            string new_signature = build_player_state_signature();
            if (new_signature == player_state_signature) {
                return;
            }

            player_state_signature = new_signature;
            notify_layout_changed();
        }

        private string build_player_state_signature() {
            if (player == null) {
                return "none";
            }

            var signature = new StringBuilder();
            signature.append_printf(
                "%s\x1f%s\x1f%s\x1f%s\x1f%d\x1f%d\x1f%d\x1f%d\x1f%d\x1f%d\x1f%d\x1f%d\x1f%d\x1f%s\x1f%d\x1f%s",
                player.title,
                player.artist,
                player.album,
                player.playback_status,
                player.can_go_previous ? 1 : 0,
                player.can_go_next ? 1 : 0,
                player.can_play ? 1 : 0,
                player.can_pause ? 1 : 0,
                player.can_control ? 1 : 0,
                player.has_volume ? 1 : 0,
                current_volume_percent(),
                player.has_shuffle ? 1 : 0,
                player.shuffle ? 1 : 0,
                player.loop_status,
                player.has_track_list ? 1 : 0,
                player.track_id
            );
            foreach (MprisTrack track in player.queue) {
                signature.append_printf(
                    "\x1e%s\x1f%s\x1f%s\x1f%s",
                    track.id,
                    track.title,
                    track.artist,
                    track.album
                );
            }
            return signature.str;
        }

        private int[] all_ids() {
            int[] ids = {
                ROOT_ID,
                SHOW_ID,
                HIDE_ID,
                COMPACT_MODE_ID,
                PREFERENCES_ID,
                ABOUT_ID,
                QUIT_ID,
                MEDIA_SEPARATOR_ID,
                SETTINGS_SEPARATOR_ID,
                UPDATE_ID,
                TITLE_ID,
                ARTIST_ID,
                ALBUM_ID,
                NO_PLAYER_ID,
                CONTROLS_SEPARATOR_ID,
                PREVIOUS_ID,
                PLAY_PAUSE_ID,
                NEXT_ID,
                SHUFFLE_ID,
                REPEAT_ID,
                REPEAT_NONE_ID,
                REPEAT_TRACK_ID,
                REPEAT_PLAYLIST_ID,
                VOLUME_ID,
                MUTE_ID,
                VOLUME_25_ID,
                VOLUME_50_ID,
                VOLUME_75_ID,
                VOLUME_100_ID,
                QUEUE_ID,
                QUEUE_EMPTY_ID
            };
            if (player != null && player.has_track_list) {
                for (int index = 0; index < player.queue.length; index++) {
                    ids += QUEUE_TRACK_BASE_ID + index;
                }
            }
            return ids;
        }

        private bool is_known_id(int id) {
            foreach (int known_id in all_ids()) {
                if (id == known_id) {
                    return true;
                }
            }
            return false;
        }

        private bool is_separator(int id) {
            return id == MEDIA_SEPARATOR_ID
                || id == SETTINGS_SEPARATOR_ID
                || id == CONTROLS_SEPARATOR_ID;
        }

        private bool is_enabled(int id) {
            if (id == SHOW_ID) {
                return !window_shown;
            }
            if (id == HIDE_ID) {
                return window_shown;
            }
            if (
                id == TITLE_ID
                || id == ARTIST_ID
                || id == ALBUM_ID
                || id == NO_PLAYER_ID
            ) {
                return false;
            }
            if (id == PREVIOUS_ID) {
                return player != null && player.can_go_previous;
            }
            if (id == PLAY_PAUSE_ID) {
                return player != null
                    && (
                        player.playback_status == "Playing"
                            ? player.can_pause
                            : player.can_play
                    );
            }
            if (id == NEXT_ID) {
                return player != null && player.can_go_next;
            }
            if (id == SHUFFLE_ID) {
                return player != null && player.has_shuffle && player.can_control;
            }
            if (id == REPEAT_ID || is_repeat_mode(id)) {
                return player != null && player.has_loop_status && player.can_control;
            }
            if (id == QUEUE_ID) {
                return player != null && player.has_track_list;
            }
            if (id == QUEUE_EMPTY_ID) {
                return false;
            }
            if (is_queue_track(id)) {
                return player != null && player.has_track_list;
            }
            if (id == VOLUME_ID || id == MUTE_ID || is_volume_preset(id)) {
                return player != null && player.has_volume && player.can_control;
            }
            return true;
        }

        private bool is_visible(int id) {
            if (id == SHOW_ID) {
                return !window_shown;
            }
            if (id == HIDE_ID) {
                return window_shown;
            }
            return id != UPDATE_ID || update_version != "";
        }

        private string get_icon_name(int id) {
            switch (id) {
                case PREVIOUS_ID:
                    return "media-skip-backward-symbolic";
                case PLAY_PAUSE_ID:
                    return player != null && player.playback_status == "Playing"
                        ? "media-playback-pause-symbolic"
                        : "media-playback-start-symbolic";
                case NEXT_ID:
                    return "media-skip-forward-symbolic";
                case SHUFFLE_ID:
                    return "media-playlist-shuffle-symbolic";
                case REPEAT_ID:
                case REPEAT_NONE_ID:
                case REPEAT_PLAYLIST_ID:
                    return "media-playlist-repeat-symbolic";
                case REPEAT_TRACK_ID:
                    return "media-playlist-repeat-song-symbolic";
                case QUEUE_ID:
                    return "view-list-symbolic";
                case VOLUME_ID:
                    return current_volume_percent() == 0
                        ? "audio-volume-muted-symbolic"
                        : "audio-volume-high-symbolic";
                case MUTE_ID:
                    return "audio-volume-muted-symbolic";
                case UPDATE_ID:
                    return "software-update-available-symbolic";
                default:
                    return "";
            }
        }

        private bool is_volume_preset(int id) {
            return id >= VOLUME_25_ID && id <= VOLUME_100_ID;
        }

        private bool volume_matches_preset(int id) {
            if (player == null) {
                return false;
            }

            int preset = (id - VOLUME_25_ID + 1) * 25;
            return current_volume_percent() == preset;
        }

        private bool is_repeat_mode(int id) {
            return id >= REPEAT_NONE_ID && id <= REPEAT_PLAYLIST_ID;
        }

        private string repeat_label() {
            if (player == null || player.loop_status == "None") {
                return _("Repeat: Off");
            }
            if (player.loop_status == "Track") {
                return _("Repeat: Current Track");
            }
            return _("Repeat: Queue");
        }

        private bool is_queue_track(int id) {
            if (player == null || !player.has_track_list || id < QUEUE_TRACK_BASE_ID) {
                return false;
            }

            int index = id - QUEUE_TRACK_BASE_ID;
            return index >= 0 && index < player.queue.length;
        }

        private string queue_track_label(int id) {
            if (!is_queue_track(id)) {
                return "";
            }

            MprisTrack track = player.queue[id - QUEUE_TRACK_BASE_ID];
            string label = track.artist == ""
                ? track.title
                : _("%s — %s").printf(track.title, track.artist);
            return truncate_label(label, 40);
        }

        private bool item_is_selected(int id) {
            if (is_volume_preset(id)) {
                return volume_matches_preset(id);
            }
            if (player == null) {
                return false;
            }
            if (is_repeat_mode(id)) {
                switch (id) {
                    case REPEAT_NONE_ID:
                        return player.loop_status == "None";
                    case REPEAT_TRACK_ID:
                        return player.loop_status == "Track";
                    case REPEAT_PLAYLIST_ID:
                        return player.loop_status == "Playlist";
                }
            }
            if (is_queue_track(id)) {
                int index = id - QUEUE_TRACK_BASE_ID;
                if (player.queue[index].id != player.track_id) {
                    return false;
                }
                for (int earlier = 0; earlier < index; earlier++) {
                    if (player.queue[earlier].id == player.track_id) {
                        return false;
                    }
                }
                return true;
            }
            return false;
        }

        private int current_volume_percent() {
            return player == null ? 0 : (int) (player.volume * 100.0 + 0.5);
        }

        private string escape_label(string label) {
            return label.replace("_", "__");
        }

        private string truncate_label(string label, int max_chars) {
            if (label.char_count() <= max_chars) {
                return escape_label(label);
            }

            int end = label.index_of_nth_char(max_chars - 1);
            return escape_label(label.substring(0, end)) + "…";
        }
    }

    public class StatusIndicator : Object {
        private const string WATCHER_BUS_NAME = "org.kde.StatusNotifierWatcher";
        private const string WATCHER_OBJECT_PATH = "/StatusNotifierWatcher";
        private const string WATCHER_IFACE = "org.kde.StatusNotifierWatcher";
        private const string DBUS_BUS_NAME = "org.freedesktop.DBus";
        private const string DBUS_OBJECT_PATH = "/org/freedesktop/DBus";
        private const string DBUS_IFACE = "org.freedesktop.DBus";
        private const string ITEM_OBJECT_PATH = "/StatusNotifierItem";
        private const string MENU_OBJECT_PATH = "/StatusNotifierMenu";

        private DBusConnection? bus;
        private StatusNotifierItem? item;
        private StatusNotifierMenu? menu;
        private uint item_registration_id = 0;
        private uint menu_registration_id = 0;
        private uint name_owner_subscription_id = 0;
        private uint volume_icon_timeout_id = 0;
        private bool enabled = false;
        private bool compact_mode = false;
        private bool window_shown = false;
        private MprisPlayer? player;
        private string update_version = "";

        public bool supported { get; private set; default = false; }

        public signal void support_changed();
        public signal void activated();
        public signal void action_requested(string action);

        public StatusIndicator() {
            if (is_flatpak()) {
                return;
            }

            try {
                bus = Bus.get_sync(BusType.SESSION);
            } catch (Error error) {
                warning("Unable to connect to the session bus for the status indicator: %s", error.message);
                return;
            }

            subscribe_name_owner_changes();
            refresh_supported();
        }

        public void set_enabled(bool enabled) {
            this.enabled = enabled;
            update_registration();
        }

        public void set_compact_mode(bool enabled) {
            compact_mode = enabled;

            if (menu != null) {
                menu.set_compact_mode(enabled);
            }
        }

        public void set_window_shown(bool shown) {
            window_shown = shown;

            if (menu != null) {
                menu.set_window_shown(shown);
            }
        }

        public void set_player(MprisPlayer? selected_player) {
            player = selected_player;

            if (menu != null) {
                menu.set_player(selected_player);
            }
        }

        public void set_update_available(string version) {
            update_version = version;

            if (menu != null) {
                menu.set_update_available(version);
            }
        }

        public void shutdown() {
            clear_volume_icon_timeout();
            if (bus != null && name_owner_subscription_id != 0) {
                bus.signal_unsubscribe(name_owner_subscription_id);
                name_owner_subscription_id = 0;
            }

            unregister_item();
        }

        private void subscribe_name_owner_changes() {
            name_owner_subscription_id = bus.signal_subscribe(
                DBUS_BUS_NAME,
                DBUS_IFACE,
                "NameOwnerChanged",
                DBUS_OBJECT_PATH,
                WATCHER_BUS_NAME,
                DBusSignalFlags.NONE,
                on_name_owner_changed
            );
        }

        private void on_name_owner_changed(
            DBusConnection connection,
            string? sender_name,
            string object_path,
            string interface_name,
            string signal_name,
            Variant parameters
        ) {
            refresh_supported();
        }

        private void refresh_supported() {
            bool old_supported = supported;
            supported = name_has_owner(WATCHER_BUS_NAME);

            if (old_supported != supported) {
                support_changed();
            }

            update_registration();
        }

        private bool name_has_owner(string name) {
            if (bus == null) {
                return false;
            }

            try {
                Variant result = bus.call_sync(
                    DBUS_BUS_NAME,
                    DBUS_OBJECT_PATH,
                    DBUS_IFACE,
                    "NameHasOwner",
                    new Variant("(s)", name),
                    new VariantType("(b)"),
                    DBusCallFlags.NONE,
                    -1
                );
                return result.get_child_value(0).get_boolean();
            } catch (Error error) {
                debug("Unable to check status indicator support: %s", error.message);
                return false;
            }
        }

        private void update_registration() {
            if (!enabled || !supported || bus == null) {
                unregister_item();
                return;
            }

            register_item();
        }

        private void register_item() {
            if (item_registration_id != 0) {
                register_with_watcher();
                return;
            }

            item = new StatusNotifierItem();
            item.activated.connect(() => activated());
            item.scroll_requested.connect((delta, orientation) => {
                if (
                    orientation != "vertical"
                    || delta == 0
                    || player == null
                    || !player.has_volume
                    || !player.can_control
                ) {
                    return;
                }

                action_requested(delta > 0 ? "volume-down" : "volume-up");
                show_volume_icon_feedback();
            });
            menu = new StatusNotifierMenu();
            menu.set_compact_mode(compact_mode);
            menu.set_window_shown(window_shown);
            menu.set_player(player);
            menu.set_update_available(update_version);
            menu.action_requested.connect((action) => action_requested(action));

            try {
                menu_registration_id = bus.register_object(MENU_OBJECT_PATH, menu);
                item_registration_id = bus.register_object(ITEM_OBJECT_PATH, item);
            } catch (IOError error) {
                warning("Unable to export status indicator: %s", error.message);
                unregister_item();
                return;
            }

            register_with_watcher();
        }

        private void register_with_watcher() {
            try {
                bus.call_sync(
                    WATCHER_BUS_NAME,
                    WATCHER_OBJECT_PATH,
                    WATCHER_IFACE,
                    "RegisterStatusNotifierItem",
                    new Variant("(s)", bus.get_unique_name()),
                    null,
                    DBusCallFlags.NONE,
                    -1
                );
            } catch (Error error) {
                debug("Unable to register status indicator with watcher: %s", error.message);
            }
        }

        private void unregister_item() {
            clear_volume_icon_timeout();
            if (bus != null && item_registration_id != 0) {
                bus.unregister_object(item_registration_id);
                item_registration_id = 0;
            }
            if (bus != null && menu_registration_id != 0) {
                bus.unregister_object(menu_registration_id);
                menu_registration_id = 0;
            }

            item = null;
            menu = null;
        }

        private void show_volume_icon_feedback() {
            if (item == null || player == null) {
                return;
            }

            item.show_volume_icon(player.volume);
            clear_volume_icon_timeout();
            volume_icon_timeout_id = Timeout.add(1500, () => {
                volume_icon_timeout_id = 0;
                if (item != null) {
                    item.restore_app_icon();
                }
                return Source.REMOVE;
            });
        }

        private void clear_volume_icon_timeout() {
            if (volume_icon_timeout_id == 0) {
                return;
            }

            Source.remove(volume_icon_timeout_id);
            volume_icon_timeout_id = 0;
        }

        private static bool is_flatpak() {
            return FileUtils.test("/.flatpak-info", FileTest.EXISTS);
        }
    }
}
