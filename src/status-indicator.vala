namespace MprisMiniPlayer {
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

    private class StatusQueueItem : Object {
        public int menu_id;
        public MprisTrack track;

        public StatusQueueItem(int menu_id, MprisTrack track) {
            this.menu_id = menu_id;
            this.track = track;
        }
    }

    private class StatusQueueGroup : Object {
        public int menu_id;
        public int start_index;
        public int end_index;
        public StatusQueueGroup[] children = {};

        public StatusQueueGroup(int menu_id, int start_index, int end_index) {
            this.menu_id = menu_id;
            this.start_index = start_index;
            this.end_index = end_index;
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
        private const int MAX_QUEUE_LAYOUT_CHILDREN = 64;

        private uint revision = 1;
        private bool compact_mode = false;
        private bool window_shown = false;
        private MprisPlayer? player;
        private ulong player_changed_handler_id = 0;
        private string player_state_signature = "none";
        private uint64 synced_queue_revision = uint64.MAX;
        private string update_version = "";
        private StatusQueueItem[] queue_items = {};
        private StatusQueueGroup[] queue_groups = {};
        private HashTable<int, StatusQueueItem> queue_items_by_id =
            new HashTable<int, StatusQueueItem>(direct_hash, direct_equal);
        private HashTable<int, StatusQueueGroup> queue_groups_by_id =
            new HashTable<int, StatusQueueGroup>(direct_hash, direct_equal);
        private string indexed_current_track_id = "";
        private int current_queue_menu_id = -1;
        private int next_queue_menu_id = QUEUE_TRACK_BASE_ID;

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
            queue_items = {};
            queue_groups = {};
            queue_items_by_id.remove_all();
            queue_groups_by_id.remove_all();
            indexed_current_track_id = "";
            current_queue_menu_id = -1;
            synced_queue_revision = uint64.MAX;
            if (player != null) {
                player_changed_handler_id = player.changed.connect(on_player_changed);
            }
            sync_queue_items();
            synced_queue_revision = player != null ? player.queue_revision : 0;
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
                StatusQueueGroup? queue_group = find_queue_group(parent_id);
                layout = queue_group != null
                    ? build_queue_group_item(queue_group, recursion_depth)
                    : build_item(parent_id);
            }
        }

        [DBus (name = "GetGroupProperties", signature = "a(ia{sv})")]
        public Variant get_group_properties(int[] ids, string[] property_names) throws DBusError, IOError {
            var items = new VariantBuilder(new VariantType("a(ia{sv})"));
            int[] requested_ids = ids.length == 0
                ? default_group_property_ids()
                : ids;

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
            return is_queue_group(id);
        }

        [DBus (name = "AboutToShowGroup")]
        public void about_to_show_group(
            int[] ids,
            out int[] updates_needed,
            out int[] id_errors
        ) throws DBusError, IOError {
            int[] needed = {};
            int[] errors = {};
            foreach (int id in ids) {
                if (is_queue_group(id)) {
                    needed += id;
                } else if (!is_known_id(id)) {
                    errors += id;
                }
            }
            updates_needed = needed;
            id_errors = errors;
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
                if (queue_items.length == 0) {
                    children.add_value(new Variant.variant(build_item(QUEUE_EMPTY_ID)));
                } else if (queue_groups.length > 0) {
                    foreach (StatusQueueGroup group in queue_groups) {
                        children.add_value(new Variant.variant(
                            build_queue_group_item(group, 0)
                        ));
                    }
                } else {
                    foreach (StatusQueueItem item in queue_items) {
                        children.add_value(new Variant.variant(
                            build_item(item.menu_id)
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

        private Variant build_queue_group_item(
            StatusQueueGroup group,
            int recursion_depth = -1
        ) {
            var children = new VariantBuilder(new VariantType("av"));
            if (recursion_depth != 0) {
                if (group.children.length > 0) {
                    foreach (StatusQueueGroup child in group.children) {
                        children.add_value(new Variant.variant(
                            build_queue_group_item(child, 0)
                        ));
                    }
                } else {
                    for (int index = group.start_index; index < group.end_index; index++) {
                        children.add_value(new Variant.variant(
                            build_item(queue_items[index].menu_id)
                        ));
                    }
                }
            }

            return new Variant.tuple({
                new Variant.int32(group.menu_id),
                build_properties(group.menu_id),
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
            if (
                id == VOLUME_ID
                || id == REPEAT_ID
                || id == QUEUE_ID
                || is_queue_group(id)
            ) {
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
                    return player != null && player.display_volume > 0.0
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
                    if (is_queue_track(id)) {
                        return queue_track_label(id);
                    }
                    StatusQueueGroup? group = find_queue_group(id);
                    return group != null
                        ? "%d–%d".printf(group.start_index + 1, group.end_index)
                        : "";
            }
        }

        private void activate_item(int id) {
            StatusQueueItem? queue_item = find_queue_item(id);
            if (queue_item != null) {
                if (player != null) {
                    player.go_to(queue_item.track.id);
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
            bool queue_layout_changed = false;
            uint64 queue_revision = player != null ? player.queue_revision : 0;
            if (queue_revision != synced_queue_revision) {
                queue_layout_changed = sync_queue_items();
                synced_queue_revision = queue_revision;
            }
            sync_current_queue_menu_id();
            string new_signature = build_player_state_signature();
            if (
                new_signature == player_state_signature
                && !queue_layout_changed
            ) {
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
            signature.append(new Variant.strv({ player.title, player.artist, player.album,
                player.playback_status, player.loop_status, player.track_id }).print(true));
            int[] values = {
                player.can_go_previous ? 1 : 0, player.can_go_next ? 1 : 0,
                player.can_play ? 1 : 0, player.can_pause ? 1 : 0,
                player.can_control ? 1 : 0, player.has_volume ? 1 : 0,
                current_volume_percent(), player.has_shuffle ? 1 : 0,
                player.shuffle ? 1 : 0, player.has_loop_status ? 1 : 0,
                player.has_track_list ? 1 : 0
            };
            foreach (int value in values) signature.append_printf(";%d", value);
            return signature.str;
        }

        private int[] base_ids() {
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
            return ids;
        }

        private int[] default_group_property_ids() {
            int[] ids = base_ids();
            if (player != null && player.has_track_list) {
                if (queue_groups.length > 0) {
                    foreach (StatusQueueGroup group in queue_groups) {
                        ids += group.menu_id;
                    }
                } else {
                    foreach (StatusQueueItem item in queue_items) {
                        ids += item.menu_id;
                    }
                }
            }
            return ids;
        }

        private bool is_known_id(int id) {
            foreach (int known_id in base_ids()) {
                if (id == known_id) {
                    return true;
                }
            }
            if (player != null && player.has_track_list) {
                return queue_items_by_id.contains(id)
                    || queue_groups_by_id.contains(id);
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
                return player != null && player.available && player.can_control && player.can_go_previous;
            }
            if (id == PLAY_PAUSE_ID) {
                return player != null && player.can_play_pause;
            }
            if (id == NEXT_ID) {
                return player != null && player.available && player.can_control && player.can_go_next;
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
            if (is_queue_group(id)) {
                return true;
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
            return find_queue_item(id) != null;
        }

        private bool is_queue_group(int id) {
            return find_queue_group(id) != null;
        }

        private string queue_track_label(int id) {
            StatusQueueItem? queue_item = find_queue_item(id);
            if (queue_item == null) {
                return "";
            }

            MprisTrack track = queue_item.track;
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
                return id == current_queue_menu_id;
            }
            return false;
        }

        private StatusQueueItem? find_queue_item(int menu_id) {
            return queue_items_by_id.lookup(menu_id);
        }

        private StatusQueueGroup? find_queue_group(int menu_id) {
            return queue_groups_by_id.lookup(menu_id);
        }

        private bool sync_queue_items() {
            if (player == null || !player.has_track_list) {
                bool had_queue_items = queue_items.length > 0
                    || queue_groups.length > 0;
                queue_items = {};
                queue_groups = {};
                queue_items_by_id.remove_all();
                queue_groups_by_id.remove_all();
                sync_current_queue_menu_id(true);
                return had_queue_items;
            }

            bool same_visible_state = queue_items.length == player.queue.length;
            if (same_visible_state) {
                for (int index = 0; index < player.queue.length; index++) {
                    MprisTrack previous = queue_items[index].track;
                    MprisTrack current = player.queue[index];
                    if (
                        previous.id != current.id
                        || previous.title != current.title
                        || previous.artist != current.artist
                        || previous.album != current.album
                    ) {
                        same_visible_state = false;
                        break;
                    }
                }
            }
            if (same_visible_state) {
                for (int index = 0; index < player.queue.length; index++) {
                    queue_items[index].track = player.queue[index];
                }
                sync_current_queue_menu_id(true);
                return false;
            }

            queue_items_by_id.remove_all();
            StatusQueueItem[] updated_items = new StatusQueueItem[player.queue.length];
            for (int index = 0; index < player.queue.length; index++) {
                updated_items[index] = new StatusQueueItem(
                    next_queue_menu_id++,
                    player.queue[index]
                );
                queue_items_by_id.insert(
                    updated_items[index].menu_id,
                    updated_items[index]
                );
            }
            queue_items = updated_items;
            queue_groups_by_id.remove_all();
            queue_groups = build_queue_groups(0, queue_items.length);
            sync_current_queue_menu_id(true);
            return true;
        }

        private void sync_current_queue_menu_id(bool force = false) {
            string track_id = player != null ? player.track_id : "";
            if (!force && track_id == indexed_current_track_id) {
                return;
            }

            indexed_current_track_id = track_id;
            current_queue_menu_id = -1;
            if (track_id == "") {
                return;
            }
            foreach (StatusQueueItem item in queue_items) {
                if (item.track.id == track_id) {
                    current_queue_menu_id = item.menu_id;
                    return;
                }
            }
        }

        private StatusQueueGroup[] build_queue_groups(int start_index, int end_index) {
            int length = end_index - start_index;
            if (length <= MAX_QUEUE_LAYOUT_CHILDREN) {
                return {};
            }

            int group_span = 1;
            while (
                ((length - 1) / group_span) + 1 > MAX_QUEUE_LAYOUT_CHILDREN
            ) {
                group_span *= MAX_QUEUE_LAYOUT_CHILDREN;
            }

            StatusQueueGroup[] groups = {};
            for (int start = start_index; start < end_index; start += group_span) {
                int end = int.min(start + group_span, end_index);
                var group = new StatusQueueGroup(next_queue_menu_id++, start, end);
                group.children = build_queue_groups(start, end);
                groups += group;
                queue_groups_by_id.insert(group.menu_id, group);
            }
            return groups;
        }

        private int current_volume_percent() {
            return player == null ? 0 : (int) double.min(int.MAX, player.display_volume * 100.0 + 0.5);
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
        private const string ITEM_OBJECT_PATH = "/StatusNotifierItem";
        private const string MENU_OBJECT_PATH = "/StatusNotifierMenu";

        private DBusConnection? bus;
        private StatusNotifierItem? item;
        private StatusNotifierMenu? menu;
        private uint item_registration_id = 0;
        private uint menu_registration_id = 0;
        private uint watcher_id = 0;
        private uint item_name_id = 0;
        private string item_bus_name = "";
        private string item_name_prefix = "";
        private uint item_generation;
        private string watcher_owner = "";
        private bool stopped = false;
        private Cancellable lifetime = new Cancellable();
        private Cancellable? registration_request;
        private uint volume_icon_timeout_id = 0;
        private uint registration_retry;
        private uint registration_attempts;
        private bool enabled = false;
        private bool compact_mode = false;
        private bool window_shown = false;
        private MprisPlayer? player;
        private ulong player_changed_handler_id = 0;
        private string update_version = "";

        public bool supported { get; private set; default = false; }

        public signal void support_changed();
        public signal void activated();
        public signal void action_requested(string action);

        public StatusIndicator() {
            if (!is_flatpak()) initialize.begin();
        }

        internal StatusIndicator.with_connection(DBusConnection connection) {
            initialize.begin(connection);
        }

        private async void initialize(DBusConnection? connection = null) {
            try {
                bus = connection ?? (yield Bus.get(BusType.SESSION, lifetime));
                if (stopped) return;
                item_name_prefix = "org.kde.StatusNotifierItem.MprisMiniPlayer%s".printf(
                    bus.get_unique_name().replace(":", "_").replace(".", "_"));
                watcher_id = Bus.watch_name_on_connection(bus, WATCHER_BUS_NAME, BusNameWatcherFlags.NONE,
                    (connection, name, owner) => {
                        watcher_owner = owner;
                        supported = true;
                        support_changed();
                        update_registration();
                    },
                    () => {
                        watcher_owner = "";
                        supported = false;
                        support_changed();
                        update_registration();
                    });
            } catch (Error error) {
                if (!stopped) debug("Unable to connect status indicator: %s", error.message);
            }
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
            if (player == selected_player) return;
            if (player != null && player_changed_handler_id != 0) {
                SignalHandler.disconnect(player, player_changed_handler_id);
                player_changed_handler_id = 0;
            }
            clear_volume_icon_timeout();
            if (item != null) item.restore_app_icon();
            player = selected_player;
            if (player != null) {
                player_changed_handler_id = player.changed.connect(update_volume_icon_feedback);
            }

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
            if (stopped) return;
            stopped = true;
            lifetime.cancel();
            if (watcher_id != 0) { Bus.unwatch_name(watcher_id); watcher_id = 0; }
            unregister_item();
            set_player(null);
        }

        private void update_registration() {
            if (stopped || !enabled || !supported || bus == null) {
                unregister_item();
                return;
            }

            register_item();
        }

        private void register_item() {
            if (item_registration_id != 0) {
                return;
            }

            registration_attempts = 0;
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

            // Watchers remove items when this dedicated name disappears, even
            // though the application's shared session-bus connection stays alive.
            uint version = ++item_generation;
            item_bus_name = "%s.i%u".printf(item_name_prefix, version);
            item_name_id = Bus.own_name_on_connection(bus, item_bus_name, BusNameOwnerFlags.NONE,
                () => {
                    if (!stopped && version == item_generation && item_registration_id != 0) register_with_watcher.begin();
                },
                () => { if (!stopped && version == item_generation) unregister_item(); });
        }

        private async void register_with_watcher() {
            if (registration_request != null) registration_request.cancel();
            registration_request = new Cancellable();
            var request = registration_request;
            string owner = watcher_owner;
            registration_attempts++;
            try {
                yield bus.call(
                    owner,
                    WATCHER_OBJECT_PATH,
                    WATCHER_IFACE,
                    "RegisterStatusNotifierItem",
                    new Variant("(s)", item_bus_name),
                    new VariantType("()"),
                    DBusCallFlags.NO_AUTO_START,
                    3000,
                    request
                );
            } catch (Error error) {
                if (stopped || request.is_cancelled() || owner != watcher_owner) return;
                debug("Unable to register status indicator with watcher: %s", error.message);
                if (registration_attempts < 3 && item_registration_id != 0) {
                    registration_retry = Timeout.add_seconds(registration_attempts, () => {
                        registration_retry = 0;
                        register_with_watcher.begin();
                        return Source.REMOVE;
                    });
                }
            }
        }

        private void unregister_item() {
            item_generation++;
            clear_volume_icon_timeout();
            if (registration_retry != 0) { Source.remove(registration_retry); registration_retry = 0; }
            if (registration_request != null) { registration_request.cancel(); registration_request = null; }
            if (item_name_id != 0) { Bus.unown_name(item_name_id); item_name_id = 0; }
            if (menu != null) menu.set_player(null);
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

            item.show_volume_icon(player.display_volume);
            clear_volume_icon_timeout();
            volume_icon_timeout_id = Timeout.add(1500, () => {
                volume_icon_timeout_id = 0;
                if (item != null) {
                    item.restore_app_icon();
                }
                return Source.REMOVE;
            });
        }

        private void update_volume_icon_feedback() {
            if (volume_icon_timeout_id != 0 && item != null && player != null) {
                item.show_volume_icon(player.display_volume);
            }
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
