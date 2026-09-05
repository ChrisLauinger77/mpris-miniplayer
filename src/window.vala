namespace MprisMiniPlayer {
    private class QueueItemView : Gtk.Box {
        public ulong current_track_handler_id = 0;
        private Gtk.Label title_label;
        private Gtk.Label artist_label;
        private Gtk.Image current_icon;

        public QueueItemView() {
            Object(orientation: Gtk.Orientation.HORIZONTAL, spacing: 10);
            margin_top = 8;
            margin_bottom = 8;
            margin_start = 10;
            margin_end = 10;

            var labels = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
            labels.hexpand = true;
            append(labels);

            title_label = new Gtk.Label("");
            title_label.halign = Gtk.Align.START;
            title_label.ellipsize = Pango.EllipsizeMode.END;
            labels.append(title_label);

            artist_label = new Gtk.Label("");
            artist_label.halign = Gtk.Align.START;
            artist_label.ellipsize = Pango.EllipsizeMode.END;
            artist_label.add_css_class("dim-label");
            labels.append(artist_label);

            current_icon = new Gtk.Image.from_icon_name(
                "media-playback-start-symbolic"
            );
            current_icon.tooltip_text = _("Currently playing");
            current_icon.visible = false;
            append(current_icon);
        }

        public void bind_track(
            MprisTrack track,
            string accessible_label,
            bool current
        ) {
            title_label.label = track.title;
            title_label.tooltip_text = track.title;
            artist_label.label = track.artist;
            artist_label.tooltip_text = track.artist;
            artist_label.visible = track.artist != "";
            if (current) {
                title_label.add_css_class("heading");
            } else {
                title_label.remove_css_class("heading");
            }
            current_icon.visible = current;
            tooltip_text = accessible_label;
            update_property(Gtk.AccessibleProperty.LABEL, accessible_label);
        }
    }

    public class Window : Adw.ApplicationWindow {
        private const int64 MAX_ARTWORK_BYTES = 10 * 1024 * 1024;
        private const int MAX_ARTWORK_DIMENSION = 8192;
        private const int64 MAX_ARTWORK_PIXELS = 16 * 1024 * 1024;
        private const int ARTWORK_DECODE_SIZE = 256;
        private const size_t ARTWORK_READ_CHUNK_BYTES = 64 * 1024;
        private const uint ARTWORK_TIMEOUT_SECONDS = 15;

        private MprisManager? manager;
        private MprisPlayer? player;
        private ulong player_changed_handler_id = 0;
        private bool compact_mode = false;
        private bool album_tint_enabled = false;
        private bool keep_queue_open = true;
        private string current_art_url = "";
        private uint artwork_request_id = 0;
        private Soup.Session artwork_session;
        private Cancellable? artwork_cancellable;
        private bool stopped = false;
        private ulong manager_changed_handler_id;
        private uint queue_scroll_source;
        private Gtk.EventControllerLegacy seek_events;
        private uint seek_release_source;
        private Gtk.EventControllerLegacy volume_events;
        private uint volume_release_source;
        private MprisPlayer? seek_player;
        private MprisPlayer? volume_player;
        private uint64 seek_track_revision;
        private bool dragging_seek = false;
        private bool dragging_volume = false;
        private Gdk.Pixbuf? current_artwork_pixbuf;
        private Gtk.CssProvider tint_provider;

        private Gtk.Box main_box;
        private Gtk.Stack cover_stack;
        private Gtk.Picture cover;
        private Gtk.Image empty_icon;
        private Gtk.Box progress_row;
        private Gtk.Label title_label;
        private Gtk.Label artist_label;
        private Gtk.Label album_label;
        private Gtk.Scale progress_scale;
        private Gtk.Label time_label;
        private Gtk.Box volume_box;
        private Gtk.Button volume_button;
        private Gtk.Image volume_icon;
        private Gtk.Scale volume_scale;
        private Gtk.Button previous_button;
        private Gtk.Button play_pause_button;
        private Gtk.Button next_button;
        private Gtk.ToggleButton shuffle_button;
        private Gtk.Image shuffle_icon;
        private Gtk.ToggleButton repeat_button;
        private Gtk.Image repeat_icon;
        private Gtk.MenuButton queue_button;
        private Gtk.Popover queue_popover;
        private Gtk.ScrolledWindow queue_scrolled;
        private Gtk.Stack queue_stack;
        private Gtk.ListView queue_list;
        private GLib.ListStore queue_store;
        private Gtk.SingleSelection queue_selection;
        private int current_queue_index = -1;
        private Menu main_menu;
        private uint64 displayed_queue_revision = uint64.MAX;
        private string displayed_queue_track_id = "";
        private bool queue_view_dirty = true;
        private Gtk.MenuButton player_button;
        private Gtk.Image player_icon;
        private Gtk.Label player_label;
        private Gtk.Popover player_popover;
        private Gtk.ListBox player_list;
        private uint position_timeout_id = 0;
        private bool updating_progress = false;
        private bool updating_volume = false;

        private signal void queue_current_track_changed();

        public Window(
            Gtk.Application app,
            MprisManager? manager,
            bool compact_mode,
            bool album_tint_enabled,
            bool keep_queue_open
        ) {
            Object(
                application: app,
                title: _("MPRIS MiniPlayer"),
                default_width: 440,
                default_height: 170
            );

            this.manager = manager;
            this.compact_mode = compact_mode;
            this.album_tint_enabled = album_tint_enabled;
            this.keep_queue_open = keep_queue_open;
            artwork_session = new Soup.Session();

            tint_provider = new Gtk.CssProvider();
            Gtk.StyleContext.add_provider_for_display(
                get_display(),
                tint_provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            );

            build_ui();
            if (manager != null) {
                manager_changed_handler_id = manager.active_player_changed.connect(sync_active_player);
            }
            set_compact_mode(compact_mode);
            map.connect(() => {
                if (player != null) player.refresh_position();
                start_position_timer();
            });
            unmap.connect(() => { stop_position_timer(); clear_interactions(); });
            refresh_players();
        }

        public void shutdown() {
            if (stopped) return;
            stopped = true;
            stop_position_timer();
            clear_interactions();
            if (queue_scroll_source != 0) { Source.remove(queue_scroll_source); queue_scroll_source = 0; }
            if (manager != null && manager_changed_handler_id != 0) {
                SignalHandler.disconnect(manager, manager_changed_handler_id);
                manager_changed_handler_id = 0;
            }
            if (player != null && player_changed_handler_id != 0) {
                SignalHandler.disconnect(player, player_changed_handler_id);
                player_changed_handler_id = 0;
            }
            player = null;
            seek_player = null;
            volume_player = null;
            artwork_request_id++;
            cancel_artwork_request();
            artwork_session.abort();
            queue_store.remove_all();
            cover.paintable = null;
            current_artwork_pixbuf = null;
            Gtk.StyleContext.remove_provider_for_display(get_display(), tint_provider);
        }

        private void clear_interactions() {
            if (seek_release_source != 0) { Source.remove(seek_release_source); seek_release_source = 0; }
            if (volume_release_source != 0) { Source.remove(volume_release_source); volume_release_source = 0; }
            dragging_seek = dragging_volume = false;
            seek_player = volume_player = null;
        }

        private void stop_position_timer() {
            if (position_timeout_id == 0) return;
            Source.remove(position_timeout_id);
            position_timeout_id = 0;
        }

        public void set_album_tint_enabled(bool enabled) {
            album_tint_enabled = enabled;
            if (!enabled) {
                clear_album_tint();
            } else if (current_artwork_pixbuf != null) {
                apply_album_tint(current_artwork_pixbuf);
            }
        }

        public void set_keep_queue_open(bool enabled) {
            keep_queue_open = enabled;
        }

        public void refresh_players() {
            sync_active_player();
        }

        public void set_compact_mode(bool compact_mode) {
            this.compact_mode = compact_mode;

            if (main_box == null) {
                return;
            }

            cover_stack.visible = !compact_mode;
            album_label.visible = !compact_mode;
            main_box.spacing = compact_mode ? 10 : 14;
            main_box.margin_top = compact_mode ? 6 : 8;
            main_box.margin_bottom = compact_mode ? 8 : 12;
            main_box.margin_start = compact_mode ? 10 : 14;
            main_box.margin_end = compact_mode ? 10 : 14;
            set_default_size(compact_mode ? 380 : 440, compact_mode ? 118 : 170);
        }

        private void build_ui() {
            var toolbar_view = new Adw.ToolbarView();
            set_content(toolbar_view);

            var header_bar = new Adw.HeaderBar();
            header_bar.show_title = false;
            header_bar.set_size_request(-1, 34);
            toolbar_view.add_top_bar(header_bar);

            var player_button_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
            player_icon = new Gtk.Image.from_icon_name("multimedia-player-symbolic");
            player_icon.pixel_size = 16;
            player_button_box.append(player_icon);

            player_label = new Gtk.Label("");
            player_label.halign = Gtk.Align.START;
            player_label.ellipsize = Pango.EllipsizeMode.END;
            player_label.max_width_chars = 22;
            player_button_box.append(player_label);

            var chevron = new Gtk.Image.from_icon_name("pan-down-symbolic");
            chevron.pixel_size = 12;
            player_button_box.append(chevron);

            player_button = new Gtk.MenuButton();
            set_control_label(player_button, _("Choose player"));
            player_button.child = player_button_box;
            player_button.halign = Gtk.Align.START;
            player_button.sensitive = false;
            header_bar.pack_start(player_button);

            var menu = new Menu();
            main_menu = menu;
            rebuild_main_menu();

            var menu_button = new Gtk.MenuButton();
            menu_button.icon_name = "open-menu-symbolic";
            set_control_label(menu_button, _("Main menu"));
            menu_button.menu_model = menu;
            header_bar.pack_end(menu_button);

            var about_button = new Gtk.Button.from_icon_name("help-about-symbolic");
            set_control_label(about_button, _("About MPRIS MiniPlayer"));
            about_button.action_name = "app.about";
            header_bar.pack_end(about_button);

            queue_button = new Gtk.MenuButton();
            queue_button.icon_name = "view-list-symbolic";
            set_control_label(queue_button, _("Queue"));
            queue_button.sensitive = false;
            header_bar.pack_end(queue_button);

            main_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 14);
            main_box.margin_top = 8;
            main_box.margin_bottom = 12;
            main_box.margin_start = 14;
            main_box.margin_end = 14;
            toolbar_view.set_content(main_box);

            cover_stack = new Gtk.Stack();
            cover_stack.set_size_request(108, 108);
            cover_stack.add_css_class("card");
            main_box.append(cover_stack);

            cover = new Gtk.Picture();
            cover.content_fit = Gtk.ContentFit.COVER;
            cover_stack.add_named(cover, "artwork");

            empty_icon = new Gtk.Image.from_icon_name("audio-x-generic-symbolic");
            empty_icon.pixel_size = 96;
            empty_icon.add_css_class("dim-label");
            cover_stack.add_named(empty_icon, "empty");

            var content = new Gtk.Box(Gtk.Orientation.VERTICAL, 5);
            content.hexpand = true;
            main_box.append(content);

            title_label = new Gtk.Label(_("No player running"));
            title_label.halign = Gtk.Align.START;
            title_label.ellipsize = Pango.EllipsizeMode.END;
            title_label.add_css_class("title-2");
            content.append(title_label);

            artist_label = new Gtk.Label(_("Start an MPRIS-compatible media player"));
            artist_label.halign = Gtk.Align.START;
            artist_label.ellipsize = Pango.EllipsizeMode.END;
            artist_label.add_css_class("dim-label");
            content.append(artist_label);

            album_label = new Gtk.Label("");
            album_label.halign = Gtk.Align.START;
            album_label.ellipsize = Pango.EllipsizeMode.END;
            album_label.add_css_class("dim-label");
            content.append(album_label);

            progress_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            content.append(progress_row);

            progress_scale = new Gtk.Scale.with_range(Gtk.Orientation.HORIZONTAL, 0, 1, 1);
            progress_scale.draw_value = false;
            progress_scale.sensitive = false;
            progress_scale.tooltip_text = _("Playback position");
            progress_scale.update_property(
                Gtk.AccessibleProperty.LABEL,
                _("Playback position")
            );
            progress_scale.hexpand = true;
            progress_scale.value_changed.connect(on_progress_value_changed);
            seek_events = new Gtk.EventControllerLegacy();
            seek_events.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            seek_events.event.connect((event) => {
                switch (event.get_event_type()) {
                    case Gdk.EventType.BUTTON_PRESS:
                    case Gdk.EventType.TOUCH_BEGIN:
                        if (seek_release_source != 0) { Source.remove(seek_release_source); seek_release_source = 0; }
                        dragging_seek = true;
                        seek_player = player;
                        seek_track_revision = player != null ? player.track_revision : 0;
                        break;
                    case Gdk.EventType.BUTTON_RELEASE:
                    case Gdk.EventType.TOUCH_END:
                    case Gdk.EventType.TOUCH_CANCEL:
                        if (seek_release_source == 0) seek_release_source = Idle.add(() => {
                            seek_release_source = 0;
                            dragging_seek = false;
                            seek_player = null;
                            update_progress();
                            return Source.REMOVE;
                        });
                        break;
                }
                return false;
            });
            progress_scale.add_controller(seek_events);
            progress_row.append(progress_scale);

            time_label = new Gtk.Label("0:00 / 0:00");
            time_label.add_css_class("dim-label");
            progress_row.append(time_label);

            var spacer = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            spacer.vexpand = true;
            content.append(spacer);

            var controls = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
            controls.valign = Gtk.Align.END;
            content.append(controls);

            volume_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 4);
            volume_box.valign = Gtk.Align.CENTER;
            volume_box.margin_end = 6;
            controls.append(volume_box);

            volume_button = new Gtk.Button();
            volume_button.has_frame = false;
            set_control_label(volume_button, _("Mute"));
            volume_button.clicked.connect(on_volume_button_clicked);
            volume_box.append(volume_button);

            volume_icon = new Gtk.Image.from_icon_name("audio-volume-high-symbolic");
            volume_icon.pixel_size = 16;
            volume_button.child = volume_icon;

            volume_scale = new Gtk.Scale.with_range(Gtk.Orientation.HORIZONTAL, 0, 1, 0.01);
            volume_scale.draw_value = false;
            volume_scale.sensitive = false;
            volume_scale.tooltip_text = _("Volume");
            volume_scale.update_property(Gtk.AccessibleProperty.LABEL, _("Volume"));
            volume_scale.set_size_request(90, -1);
            volume_scale.value_changed.connect(on_volume_value_changed);
            volume_events = new Gtk.EventControllerLegacy();
            volume_events.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            volume_events.event.connect((event) => {
                switch (event.get_event_type()) {
                    case Gdk.EventType.BUTTON_PRESS:
                    case Gdk.EventType.TOUCH_BEGIN:
                        if (volume_release_source != 0) { Source.remove(volume_release_source); volume_release_source = 0; }
                        dragging_volume = true;
                        volume_player = player;
                        break;
                    case Gdk.EventType.BUTTON_RELEASE:
                    case Gdk.EventType.TOUCH_END:
                    case Gdk.EventType.TOUCH_CANCEL:
                        if (volume_release_source == 0) volume_release_source = Idle.add(() => {
                            volume_release_source = 0;
                            dragging_volume = false;
                            volume_player = null;
                            update_volume();
                            return Source.REMOVE;
                        });
                        break;
                }
                return false;
            });
            volume_scale.add_controller(volume_events);
            volume_box.append(volume_scale);

            shuffle_button = new Gtk.ToggleButton();
            shuffle_icon = new Gtk.Image.from_icon_name("media-playlist-shuffle-symbolic");
            shuffle_button.child = shuffle_icon;
            shuffle_button.action_name = "app.shuffle";
            set_control_label(shuffle_button, _("Shuffle"));
            controls.append(shuffle_button);

            previous_button = new Gtk.Button.from_icon_name("media-skip-backward-symbolic");
            set_control_label(previous_button, _("Previous"));
            previous_button.clicked.connect(() => {
                if (player != null) {
                    player.previous();
                }
            });
            controls.append(previous_button);

            play_pause_button = new Gtk.Button.from_icon_name("media-playback-start-symbolic");
            set_control_label(play_pause_button, _("Play"));
            play_pause_button.clicked.connect(() => {
                if (player != null) {
                    player.play_pause();
                }
            });
            play_pause_button.add_css_class("suggested-action");
            controls.append(play_pause_button);

            next_button = new Gtk.Button.from_icon_name("media-skip-forward-symbolic");
            set_control_label(next_button, _("Next"));
            next_button.clicked.connect(() => {
                if (player != null) {
                    player.next();
                }
            });
            controls.append(next_button);

            repeat_button = new Gtk.ToggleButton();
            repeat_icon = new Gtk.Image.from_icon_name("media-playlist-repeat-symbolic");
            repeat_button.child = repeat_icon;
            repeat_button.action_name = "app.repeat-cycle";
            set_control_label(repeat_button, _("Repeat: Off"));
            controls.append(repeat_button);

            player_popover = new Gtk.Popover();
            player_list = new Gtk.ListBox();
            player_list.selection_mode = Gtk.SelectionMode.NONE;
            player_popover.child = player_list;
            player_button.set_popover(player_popover);

            queue_popover = new Gtk.Popover();
            queue_popover.position = Gtk.PositionType.BOTTOM;
            queue_popover.autohide = true;
            var queue_panel = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            var queue_heading = new Gtk.Label(_("Queue"));
            queue_heading.halign = Gtk.Align.START;
            queue_heading.margin_top = 10;
            queue_heading.margin_bottom = 8;
            queue_heading.margin_start = 12;
            queue_heading.margin_end = 12;
            queue_heading.add_css_class("heading");
            queue_panel.append(queue_heading);
            queue_panel.append(new Gtk.Separator(Gtk.Orientation.HORIZONTAL));
            queue_scrolled = new Gtk.ScrolledWindow();
            queue_scrolled.hscrollbar_policy = Gtk.PolicyType.NEVER;
            queue_scrolled.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
            queue_scrolled.propagate_natural_height = true;
            queue_scrolled.max_content_height = 320;
            queue_scrolled.set_size_request(340, -1);
            queue_store = new GLib.ListStore(typeof(MprisTrack));
            queue_selection = new Gtk.SingleSelection(queue_store);
            queue_selection.autoselect = false;
            queue_selection.can_unselect = true;
            var queue_factory = new Gtk.SignalListItemFactory();
            queue_factory.setup.connect((object) => {
                var list_item = object as Gtk.ListItem;
                if (list_item != null) {
                    var item_view = new QueueItemView();
                    list_item.child = item_view;
                    item_view.current_track_handler_id =
                        queue_current_track_changed.connect(() => {
                            var track = list_item.item as MprisTrack;
                            if (track != null && item_view != null) {
                                item_view.bind_track(
                                    track,
                                    queue_track_label(track),
                                    is_current_queue_track(
                                        track,
                                        list_item.position
                                    )
                                );
                            }
                        });
                }
            });
            queue_factory.teardown.connect((object) => {
                var list_item = object as Gtk.ListItem;
                var item_view = list_item != null
                    ? list_item.child as QueueItemView
                    : null;
                if (
                    item_view != null
                    && item_view.current_track_handler_id != 0
                ) {
                    SignalHandler.disconnect(
                        this,
                        item_view.current_track_handler_id
                    );
                    item_view.current_track_handler_id = 0;
                }
            });
            queue_factory.bind.connect((object) => {
                var list_item = object as Gtk.ListItem;
                var track = list_item != null ? list_item.item as MprisTrack : null;
                var item_view = list_item != null ? list_item.child as QueueItemView : null;
                if (track != null && item_view != null) {
                    item_view.bind_track(
                        track,
                        queue_track_label(track),
                        is_current_queue_track(track, list_item.position)
                    );
                }
            });
            queue_list = new Gtk.ListView(queue_selection, queue_factory);
            queue_list.single_click_activate = true;
            queue_list.activate.connect(on_queue_item_activated);
            queue_scrolled.child = queue_list;
            queue_stack = new Gtk.Stack();
            queue_stack.add_named(queue_scrolled, "tracks");
            var empty_label = new Gtk.Label(_("Queue is empty"));
            empty_label.margin_top = 18;
            empty_label.margin_bottom = 18;
            empty_label.margin_start = 18;
            empty_label.margin_end = 18;
            empty_label.add_css_class("dim-label");
            queue_stack.add_named(empty_label, "empty");
            queue_panel.append(queue_stack);
            queue_popover.child = queue_panel;
            queue_popover.notify["visible"].connect(() => {
                if (queue_popover.visible) {
                    sync_queue_views(true);
                    scroll_current_queue_row_to_center();
                }
            });
            queue_button.set_popover(queue_popover);

            update_controls(false);
        }

        private void sync_active_player() {
            if (stopped) return;
            if (manager == null || (manager.ready && (!manager.connected || manager.discovery_failed))) {
                set_player(null);
                show_empty_state(_("Session D-Bus unavailable"), _("Unable to monitor MPRIS players"));
                return;
            }

            string[] players = manager.list_players();
            rebuild_player_list(players);

            if (players.length == 0) {
                set_player(null);
                show_empty_state(_("No player detected"), _("Start any MPRIS-compatible player"));
                return;
            }

            if (manager.active_player == null) {
                set_player(null);
                show_empty_state(_("Player unavailable"), _("Unable to monitor MPRIS players"));
                return;
            }

            set_player(manager.active_player);
        }

        private void set_player(MprisPlayer? selected_player) {
            if (player == selected_player) {
                if (player != null) {
                    update_player_state();
                }
                return;
            }

            if (player != null && player_changed_handler_id != 0) {
                SignalHandler.disconnect(player, player_changed_handler_id);
                player_changed_handler_id = 0;
            }

            stop_position_timer();
            player = selected_player;
            // A drag started on the old model must never control its replacement.
            seek_player = null;
            volume_player = null;
            queue_store.remove_all();
            displayed_queue_revision = uint64.MAX;
            displayed_queue_track_id = "";
            queue_view_dirty = true;
            if (player != null) {
                player_changed_handler_id = player.changed.connect(update_player_state);
                update_player_state();
            }
        }

        private void update_player_state() {
            if (stopped || player == null) {
                return;
            }

            set_label_with_tooltip(title_label, player.title);
            set_label_with_tooltip(artist_label, player.artist);
            set_label_with_tooltip(album_label, player.album);
            player_label.label = player.display_name();
            player_icon.icon_name = player.icon_name();
            set_artwork(player.art_url);
            progress_row.visible = true;
            update_progress();
            update_volume();
            update_controls(true);
            start_position_timer();
            update_secondary_controls();
            sync_queue_views();

            if (player.playback_status == "Playing") {
                play_pause_button.icon_name = "media-playback-pause-symbolic";
                set_control_label(play_pause_button, _("Pause"));
            } else {
                play_pause_button.icon_name = "media-playback-start-symbolic";
                set_control_label(play_pause_button, _("Play"));
            }
        }

        private void show_empty_state(string title, string subtitle) {
            set_label_with_tooltip(title_label, title);
            set_label_with_tooltip(artist_label, subtitle);
            set_label_with_tooltip(album_label, "");
            player_label.label = "";
            player_icon.icon_name = "multimedia-player-symbolic";
            cover_stack.visible_child_name = "empty";
            cover.paintable = null;
            current_art_url = "";
            current_artwork_pixbuf = null;
            cancel_artwork_request();
            artwork_request_id++;
            clear_album_tint();
            progress_row.visible = false;
            progress_scale.set_value(0);
            time_label.label = "0:00 / 0:00";
            update_volume();
            update_controls(false);
            update_secondary_controls();
            displayed_queue_revision = uint64.MAX;
            displayed_queue_track_id = "";
            queue_view_dirty = true;
        }

        private void update_secondary_controls() {
            bool can_shuffle = player != null && player.has_shuffle && player.can_control;
            bool can_repeat = player != null && player.has_loop_status && player.can_control;
            bool has_track_list = player != null && player.has_track_list;

            shuffle_button.sensitive = can_shuffle;
            shuffle_button.active = player != null && player.shuffle;
            set_control_label(
                shuffle_button,
                player != null && player.shuffle ? _("Shuffle: On") : _("Shuffle: Off")
            );

            repeat_button.sensitive = can_repeat;
            repeat_button.active = player != null && player.loop_status != "None";
            if (player == null || player.loop_status == "None") {
                repeat_icon.icon_name = "media-playlist-repeat-symbolic";
                set_control_label(repeat_button, _("Repeat: Off"));
            } else if (player.loop_status == "Track") {
                repeat_icon.icon_name = "media-playlist-repeat-song-symbolic";
                set_control_label(repeat_button, _("Repeat: Current Track"));
            } else {
                repeat_icon.icon_name = "media-playlist-repeat-symbolic";
                set_control_label(repeat_button, _("Repeat: Queue"));
            }

            queue_button.sensitive = has_track_list;
            set_control_label(
                queue_button,
                has_track_list ? _("Queue") : _("Queue unavailable")
            );
            if (!has_track_list && queue_popover.visible) {
                queue_popover.popdown();
            }
        }

        private void sync_queue_views(bool force = false) {
            uint64 revision = player != null ? player.queue_revision : 0;
            string track_id = player != null ? player.track_id : "";
            bool current_track_changed = track_id != displayed_queue_track_id;
            displayed_queue_track_id = track_id;
            if (revision != displayed_queue_revision) {
                displayed_queue_revision = revision;
                queue_view_dirty = true;
            }

            if (!queue_popover.visible && !force) {
                return;
            }
            if (!queue_view_dirty) {
                if (force || current_track_changed) {
                    sync_current_queue_row();
                }
                return;
            }

            rebuild_queue_list();
            queue_view_dirty = false;
        }

        private void rebuild_main_menu() {
            if (main_menu == null) {
                return;
            }

            main_menu.remove_all();

            var settings_menu = new Menu();
            settings_menu.append(_("Compact Mode"), "app.compact-mode");
            settings_menu.append(_("Preferences"), "app.preferences");
            settings_menu.append(_("Quit"), "app.quit");
            main_menu.append_section(null, settings_menu);
        }

        private void rebuild_queue_list() {
            current_queue_index = -1;
            queue_store.remove_all();

            if (player == null || !player.has_track_list) {
                queue_stack.visible_child_name = "empty";
                return;
            }

            if (player.queue.length == 0) {
                queue_stack.visible_child_name = "empty";
                return;
            }

            queue_stack.visible_child_name = "tracks";
            foreach (var track in player.queue) {
                queue_store.append(track);
            }

            sync_current_queue_row();
        }

        private void sync_current_queue_row() {
            int previous_index = current_queue_index;
            current_queue_index = -1;
            if (player != null) {
                for (int index = 0; index < player.queue.length; index++) {
                    if (player.queue[index].id == player.track_id) {
                        current_queue_index = index;
                        break;
                    }
                }
            }

            if (current_queue_index < 0) {
                queue_selection.selected = Gtk.INVALID_LIST_POSITION;
                if (current_queue_index != previous_index) {
                    queue_current_track_changed();
                }
                return;
            }

            queue_selection.selected = (uint) current_queue_index;
            if (current_queue_index != previous_index) {
                queue_current_track_changed();
            }
            if (
                queue_popover.visible
                && current_queue_index != previous_index
            ) {
                scroll_current_queue_row_to_center();
            }
        }

        private string queue_track_label(MprisTrack track) {
            if (track.artist == "" || track.artist == _("Unknown artist")) {
                return track.title;
            }
            return _("%s — %s").printf(track.title, track.artist);
        }

        private bool is_current_queue_track(MprisTrack track, uint position) {
            return player != null
                && current_queue_index >= 0
                && position == (uint) current_queue_index
                && track.id == player.track_id;
        }

        private void on_queue_item_activated(uint position) {
            var track = queue_store.get_item(position) as MprisTrack;
            if (player != null && track != null) {
                player.go_to(track.id);
            }
            if (!keep_queue_open) {
                queue_popover.popdown();
            }
        }

        private void scroll_current_queue_row_to_center() {
            if (current_queue_index < 0) {
                return;
            }

            if (queue_scroll_source != 0) Source.remove(queue_scroll_source);
            queue_scroll_source = Idle.add(() => {
                queue_scroll_source = 0;
                if (stopped) return Source.REMOVE;
                if (current_queue_index < 0 || !queue_popover.visible) {
                    return Source.REMOVE;
                }
                queue_list.scroll_to(
                    (uint) current_queue_index,
                    Gtk.ListScrollFlags.FOCUS,
                    null
                );
                return Source.REMOVE;
            });
        }

        private void set_artwork(string art_url) {
            if (current_art_url == art_url) {
                if (art_url == "") {
                    cover.paintable = null;
                    cover_stack.visible_child_name = "empty";
                    clear_album_tint();
                }
                return;
            }

            current_art_url = art_url;
            uint request_id = ++artwork_request_id;
            current_artwork_pixbuf = null;
            cancel_artwork_request();
            cover.paintable = null;
            cover_stack.visible_child_name = "empty";
            clear_album_tint();
            if (art_url == "") {
                return;
            }

            artwork_cancellable = new Cancellable();
            load_artwork.begin(art_url, request_id, artwork_cancellable);
        }

        private async void load_artwork(
            string art_url,
            uint request_id,
            Cancellable cancellable
        ) {
            uint timeout_id = 0;
            timeout_id = Timeout.add_seconds(ARTWORK_TIMEOUT_SECONDS, () => {
                timeout_id = 0;
                cancellable.cancel();
                return Source.REMOVE;
            });

            try {
                Bytes bytes = new Bytes(null);
                string? parsed_scheme = Uri.parse_scheme(art_url);
                if (parsed_scheme == null) {
                    throw new IOError.INVALID_ARGUMENT("Artwork URI has no valid scheme");
                }

                string normalized_scheme = parsed_scheme.down();
                if (normalized_scheme == "data") {
                    bytes = decode_data_uri(art_url);
                } else if (normalized_scheme == "http" || normalized_scheme == "https") {
                    Uri uri = Uri.parse(art_url, UriFlags.NONE);
                    string scheme = uri.get_scheme().down();
                    string? host = uri.get_host();
                    if (
                        (scheme != "http" && scheme != "https")
                        || host == null
                        || host == ""
                    ) {
                        throw new IOError.INVALID_ARGUMENT("Artwork HTTP URI is invalid");
                    }

                    Soup.Message? message = new Soup.Message.from_uri("GET", uri);
                    if (message == null) {
                        throw new IOError.INVALID_ARGUMENT("Artwork HTTP URI is invalid");
                    }

                    var stream = yield artwork_session.send_async(
                        message,
                        Priority.DEFAULT,
                        cancellable
                    );

                    uint status = message.get_status();
                    if (status < 200 || status >= 300) {
                        yield close_artwork_stream(stream, cancellable);
                        throw new IOError.FAILED(
                            "Artwork request returned HTTP status %u".printf(status)
                        );
                    }

                    int64 content_length = message.get_response_headers().get_content_length();
                    if (content_length > MAX_ARTWORK_BYTES) {
                        yield close_artwork_stream(stream, cancellable);
                        throw new IOError.MESSAGE_TOO_LARGE(
                            "Album artwork exceeds the %" + int64.FORMAT + " byte limit",
                            MAX_ARTWORK_BYTES
                        );
                    }

                    try {
                        bytes = yield read_artwork_stream(stream, cancellable);
                    } finally {
                        yield close_artwork_stream(stream, cancellable);
                    }
                } else {
                    var stream = yield File.new_for_uri(art_url).read_async(
                        Priority.DEFAULT,
                        cancellable
                    );
                    try {
                        bytes = yield read_artwork_stream(stream, cancellable);
                    } finally {
                        yield close_artwork_stream(stream, cancellable);
                    }
                }

                if (request_id != artwork_request_id || cancellable.is_cancelled()) {
                    return;
                }

                Gdk.Pixbuf pixbuf = decode_artwork(bytes);
                var texture = texture_from_pixbuf(pixbuf);
                current_artwork_pixbuf = pixbuf;
                cover.paintable = texture;
                cover_stack.visible_child_name = "artwork";
                artwork_cancellable = null;
                if (album_tint_enabled) {
                    apply_album_tint(pixbuf);
                }
            } catch (Error error) {
                if (request_id == artwork_request_id) {
                    artwork_cancellable = null;
                    current_artwork_pixbuf = null;
                    cover.paintable = null;
                    cover_stack.visible_child_name = "empty";
                    clear_album_tint();
                    debug("Unable to load album artwork: %s", error.message);
                }
            } finally {
                if (timeout_id != 0) {
                    Source.remove(timeout_id);
                }
            }
        }

        private async Bytes read_artwork_stream(
            InputStream stream,
            Cancellable cancellable
        ) throws Error {
            var buffer = new MemoryOutputStream.resizable();
            int64 total_bytes = 0;

            while (true) {
                Bytes chunk = yield stream.read_bytes_async(
                    ARTWORK_READ_CHUNK_BYTES,
                    Priority.DEFAULT,
                    cancellable
                );
                size_t chunk_size = chunk.get_size();
                if (chunk_size == 0) {
                    break;
                }

                total_bytes += (int64) chunk_size;
                if (total_bytes > MAX_ARTWORK_BYTES) {
                    throw new IOError.MESSAGE_TOO_LARGE(
                        "Album artwork exceeds the %" + int64.FORMAT + " byte limit",
                        MAX_ARTWORK_BYTES
                    );
                }

                buffer.write_bytes(chunk, cancellable);
            }

            buffer.close(cancellable);
            return buffer.steal_as_bytes();
        }

        private async void close_artwork_stream(
            InputStream stream,
            Cancellable cancellable
        ) {
            try {
                yield stream.close_async(Priority.DEFAULT, cancellable);
            } catch (Error error) {
                debug("Unable to close album artwork stream: %s", error.message);
            }
        }

        private Bytes decode_data_uri(string uri) throws Error {
            int separator = uri.index_of_char(',');
            if (separator < 0) {
                throw new IOError.INVALID_ARGUMENT("Artwork data URI has no payload");
            }

            string media_type = uri.substring(5, separator - 5);
            if (!media_type.down().has_suffix(";base64")) {
                throw new IOError.NOT_SUPPORTED("Artwork data URI is not base64 encoded");
            }

            string payload = uri.substring(separator + 1);
            if ((int64) payload.length > MAX_ARTWORK_BYTES * 4 / 3 + 4) {
                throw new IOError.MESSAGE_TOO_LARGE(
                    "Album artwork exceeds the %" + int64.FORMAT + " byte limit",
                    MAX_ARTWORK_BYTES
                );
            }

            uint8[] data = Base64.decode(payload);
            if (data.length == 0) {
                throw new IOError.INVALID_DATA("Artwork data URI has an empty payload");
            }
            if ((int64) data.length > MAX_ARTWORK_BYTES) {
                throw new IOError.MESSAGE_TOO_LARGE(
                    "Album artwork exceeds the %" + int64.FORMAT + " byte limit",
                    MAX_ARTWORK_BYTES
                );
            }

            return new Bytes(data);
        }

        private Gdk.Pixbuf decode_artwork(Bytes bytes) throws Error {
            validate_static_artwork(bytes);

            var loader = new Gdk.PixbufLoader();
            bool dimensions_ready = false;
            bool dimensions_valid = false;

            loader.size_prepared.connect((width, height) => {
                dimensions_ready = true;
                dimensions_valid = (
                    width > 0
                    && height > 0
                    && width <= MAX_ARTWORK_DIMENSION
                    && height <= MAX_ARTWORK_DIMENSION
                    && (int64) width * (int64) height <= MAX_ARTWORK_PIXELS
                );

                if (!dimensions_valid) {
                    loader.set_size(1, 1);
                    return;
                }

                double scale = double.min(
                    1.0,
                    ARTWORK_DECODE_SIZE / (double) int.max(width, height)
                );
                loader.set_size(
                    int.max(1, (int) (width * scale + 0.5)),
                    int.max(1, (int) (height * scale + 0.5))
                );
            });

            loader.write_bytes(bytes);
            loader.close();
            if (!dimensions_ready) {
                throw new IOError.INVALID_DATA("Artwork has no valid dimensions");
            }
            if (!dimensions_valid) {
                throw new IOError.MESSAGE_TOO_LARGE(
                    "Album artwork dimensions exceed the supported limit"
                );
            }

            unowned Gdk.Pixbuf? loaded_pixbuf = loader.get_pixbuf();
            if (loaded_pixbuf == null) {
                throw new IOError.INVALID_DATA("Unable to decode album artwork");
            }

            Gdk.Pixbuf? pixbuf;
            if (
                loaded_pixbuf.get_width() > ARTWORK_DECODE_SIZE
                || loaded_pixbuf.get_height() > ARTWORK_DECODE_SIZE
            ) {
                double scale = double.min(
                    1.0,
                    ARTWORK_DECODE_SIZE / (double) int.max(
                        loaded_pixbuf.get_width(),
                        loaded_pixbuf.get_height()
                    )
                );
                pixbuf = loaded_pixbuf.scale_simple(
                    int.max(1, (int) (loaded_pixbuf.get_width() * scale + 0.5)),
                    int.max(1, (int) (loaded_pixbuf.get_height() * scale + 0.5)),
                    Gdk.InterpType.BILINEAR
                );
            } else {
                pixbuf = loaded_pixbuf.copy();
            }

            if (pixbuf == null) {
                throw new IOError.FAILED("Unable to copy decoded album artwork");
            }

            return pixbuf;
        }

        private Gdk.MemoryTexture texture_from_pixbuf(Gdk.Pixbuf pixbuf) {
            int width = pixbuf.get_width();
            int height = pixbuf.get_height();
            int channels = pixbuf.get_n_channels();
            int source_stride = pixbuf.get_rowstride();
            int texture_stride = width * channels;
            uint8[] texture_pixels = new uint8[texture_stride * height];
            unowned uint8[] source_pixels = pixbuf.get_pixels();

            for (int y = 0; y < height; y++) {
                int source_offset = y * source_stride;
                int texture_offset = y * texture_stride;
                for (int x = 0; x < texture_stride; x++) {
                    texture_pixels[texture_offset + x] = source_pixels[source_offset + x];
                }
            }

            Gdk.MemoryFormat format = pixbuf.get_has_alpha()
                ? Gdk.MemoryFormat.R8G8B8A8
                : Gdk.MemoryFormat.R8G8B8;
            return new Gdk.MemoryTexture(
                width,
                height,
                format,
                new Bytes.take((owned) texture_pixels),
                (size_t) texture_stride
            );
        }

        private void validate_static_artwork(Bytes bytes) throws Error {
            int size = (int) bytes.get_size();
            if (
                artwork_bytes_match(bytes, 0, "GIF87a")
                || artwork_bytes_match(bytes, 0, "GIF89a")
            ) {
                throw new IOError.NOT_SUPPORTED("GIF artwork is not supported");
            }

            if (
                size >= 3
                && bytes[0] == 0xff
                && bytes[1] == 0xd8
                && bytes[2] == 0xff
            ) {
                return;
            }

            if (size >= 2 && bytes[0] == 'B' && bytes[1] == 'M') {
                return;
            }

            if (
                size >= 8
                && bytes[0] == 0x89
                && artwork_bytes_match(bytes, 1, "PNG")
                && bytes[4] == 0x0d
                && bytes[5] == 0x0a
                && bytes[6] == 0x1a
                && bytes[7] == 0x0a
            ) {
                validate_static_png(bytes, size);
                return;
            }

            if (
                size >= 12
                && artwork_bytes_match(bytes, 0, "RIFF")
                && artwork_bytes_match(bytes, 8, "WEBP")
            ) {
                validate_static_webp(bytes, size);
                return;
            }

            throw new IOError.NOT_SUPPORTED("Artwork image format is not supported");
        }

        private void validate_static_png(Bytes bytes, int size) throws Error {
            int offset = 8;
            while (offset <= size - 12) {
                uint32 chunk_length = read_uint32_be(bytes, offset);
                if (chunk_length > (uint32) (size - offset - 12)) {
                    return;
                }

                if (artwork_bytes_match(bytes, offset + 4, "acTL")) {
                    throw new IOError.NOT_SUPPORTED("Animated artwork is not supported");
                }
                if (
                    artwork_bytes_match(bytes, offset + 4, "IDAT")
                    || artwork_bytes_match(bytes, offset + 4, "IEND")
                ) {
                    return;
                }

                offset += 12 + (int) chunk_length;
            }
        }

        private void validate_static_webp(Bytes bytes, int size) throws Error {
            int offset = 12;
            while (offset <= size - 8) {
                uint32 chunk_length = read_uint32_le(bytes, offset + 4);
                if (chunk_length > (uint32) (size - offset - 8)) {
                    return;
                }

                if (
                    artwork_bytes_match(bytes, offset, "ANIM")
                    || artwork_bytes_match(bytes, offset, "ANMF")
                    || (
                        artwork_bytes_match(bytes, offset, "VP8X")
                        && chunk_length > 0
                        && (bytes[offset + 8] & 0x02) != 0
                    )
                ) {
                    throw new IOError.NOT_SUPPORTED("Animated artwork is not supported");
                }

                int padded_length = (int) chunk_length + ((int) chunk_length & 1);
                offset += 8 + padded_length;
            }
        }

        private bool artwork_bytes_match(Bytes bytes, int offset, string text) {
            if (offset < 0 || offset + text.length > (int) bytes.get_size()) {
                return false;
            }

            for (int index = 0; index < text.length; index++) {
                if (bytes[offset + index] != (uint8) text[index]) {
                    return false;
                }
            }

            return true;
        }

        private uint32 read_uint32_be(Bytes bytes, int offset) {
            return (
                ((uint32) bytes[offset] << 24)
                | ((uint32) bytes[offset + 1] << 16)
                | ((uint32) bytes[offset + 2] << 8)
                | bytes[offset + 3]
            );
        }

        private uint32 read_uint32_le(Bytes bytes, int offset) {
            return (
                bytes[offset]
                | ((uint32) bytes[offset + 1] << 8)
                | ((uint32) bytes[offset + 2] << 16)
                | ((uint32) bytes[offset + 3] << 24)
            );
        }

        private void cancel_artwork_request() {
            if (artwork_cancellable == null) {
                return;
            }

            artwork_cancellable.cancel();
            artwork_cancellable = null;
        }

        private void apply_album_tint(Gdk.Pixbuf pixbuf) {
            int width = pixbuf.get_width();
            int height = pixbuf.get_height();
            int stride = pixbuf.get_rowstride();
            int channels = pixbuf.get_n_channels();
            unowned uint8[] pixels = pixbuf.get_pixels();

            double red = 0;
            double green = 0;
            double blue = 0;
            double weight_sum = 0;

            for (int y = 0; y < height; y++) {
                for (int x = 0; x < width; x++) {
                    int offset = y * stride + x * channels;
                    double r = pixels[offset] / 255.0;
                    double g = pixels[offset + 1] / 255.0;
                    double b = pixels[offset + 2] / 255.0;
                    double alpha = channels == 4 ? pixels[offset + 3] / 255.0 : 1.0;
                    double maximum = double.max(r, double.max(g, b));
                    double minimum = double.min(r, double.min(g, b));
                    double saturation = maximum > 0 ? (maximum - minimum) / maximum : 0;
                    double weight = (0.2 + saturation) * alpha;
                    red += r * weight;
                    green += g * weight;
                    blue += b * weight;
                    weight_sum += weight;
                }
            }

            if (weight_sum == 0) {
                clear_album_tint();
                return;
            }

            int r8 = (int) (red / weight_sum * 255 + 0.5);
            int g8 = (int) (green / weight_sum * 255 + 0.5);
            int b8 = (int) (blue / weight_sum * 255 + 0.5);
            tint_provider.load_from_string(
                (
                    ".album-tint { background-color: alpha(rgb(%d, %d, %d), 0.22); } " +
                    ".album-tint headerbar { background-color: alpha(rgb(%d, %d, %d), 0.16); }"
                ).printf(
                    r8, g8, b8, r8, g8, b8
                )
            );
            add_css_class("album-tint");
        }

        private void clear_album_tint() {
            remove_css_class("album-tint");
            tint_provider.load_from_string("");
        }

        private void set_label_with_tooltip(Gtk.Label label, string text) {
            label.label = text;
            label.tooltip_text = text == "" ? null : text;
        }

        private void set_control_label(Gtk.Widget control, string label) {
            control.tooltip_text = label;
            control.update_property(Gtk.AccessibleProperty.LABEL, label);
        }

        private void update_controls(bool has_player) {
            has_player = has_player && player.available && player.can_control;
            previous_button.sensitive = has_player && player.can_go_previous;
            play_pause_button.sensitive = has_player && player.can_play_pause;
            next_button.sensitive = has_player && player.can_go_next;
            player_button.sensitive = manager != null && manager.list_players().length > 0;
            progress_scale.sensitive = has_player && player.can_seek && player.duration_us > 0;
            volume_button.sensitive = has_player && player.has_volume && player.can_control;
            volume_scale.sensitive = has_player && player.has_volume && player.can_control;
        }

        private void rebuild_player_list(string[] bus_names) {
            Gtk.Widget? row = player_list.get_first_child();
            while (row != null) {
                Gtk.Widget next = row.get_next_sibling();
                player_list.remove(row);
                row = next;
            }

            foreach (var bus_name in bus_names) {
                var listed_player = manager.get_player(bus_name);
                if (listed_player != null) player_list.append(create_player_row(listed_player));
            }
        }

        private Gtk.Widget create_player_row(MprisPlayer listed_player) {
            var button = new Gtk.Button();
            button.sensitive = listed_player.available;
            button.has_frame = false;
            button.hexpand = true;
            button.clicked.connect(() => {
                player_popover.popdown();
                if (
                    manager != null
                ) {
                    manager.select_player(listed_player.bus_name);
                }
            });

            var box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 10);
            box.margin_top = 8;
            box.margin_bottom = 8;
            box.margin_start = 10;
            box.margin_end = 10;
            button.child = box;

            var icon = new Gtk.Image.from_icon_name(listed_player.icon_name());
            icon.pixel_size = 20;
            box.append(icon);

            var name = new Gtk.Label(listed_player.display_name());
            name.halign = Gtk.Align.START;
            name.hexpand = true;
            name.ellipsize = Pango.EllipsizeMode.END;
            box.append(name);

            if (player != null && player.bus_name == listed_player.bus_name) {
                var selected = new Gtk.Image.from_icon_name("object-select-symbolic");
                selected.pixel_size = 16;
                box.append(selected);
            }

            return button;
        }

        private void start_position_timer() {
            if (stopped || !get_mapped() || player == null || player.playback_status != "Playing") {
                stop_position_timer();
                return;
            }
            if (position_timeout_id != 0) {
                return;
            }

            position_timeout_id = Timeout.add_seconds(1, () => {
                if (player != null) {
                    update_progress();
                }

                return Source.CONTINUE;
            });
        }

        private void update_progress() {
            if (dragging_seek && player != null && seek_player == player && seek_track_revision == player.track_revision) return;
            if (player == null || player.duration_us <= 0) {
                updating_progress = true;
                progress_scale.set_range(0, 1);
                progress_scale.set_value(0);
                updating_progress = false;
                time_label.label = "0:00 / 0:00";
                return;
            }

            double duration_seconds = player.duration_us / 1000000.0;
            double position_seconds = player.position_us / 1000000.0;
            if (position_seconds < 0) {
                position_seconds = 0;
            }
            if (position_seconds > duration_seconds) {
                position_seconds = duration_seconds;
            }

            updating_progress = true;
            progress_scale.set_range(0, duration_seconds);
            progress_scale.set_value(position_seconds);
            updating_progress = false;
            time_label.label = "%s / %s".printf(
                format_time(player.position_us),
                format_time(player.duration_us)
            );
        }

        private void on_progress_value_changed() {
            if (updating_progress || player == null || !player.can_seek || player.duration_us <= 0
                || (dragging_seek && (seek_player != player || seek_track_revision != player.track_revision))) {
                return;
            }

            double target = progress_scale.get_value() * 1000000.0;
            int64 position_us = target >= int64.MAX ? int64.MAX : (int64) target;
            player.seek_to_position(position_us);
        }

        private void update_volume() {
            if (dragging_volume && player != null && volume_player == player) return;
            bool has_volume = player != null && player.has_volume;
            volume_box.visible = has_volume;

            updating_volume = true;
            volume_scale.set_value(has_volume ? slider_volume(player.volume) : 0);
            updating_volume = false;

            update_volume_button();
        }

        private void on_volume_value_changed() {
            if (updating_volume || player == null || !player.has_volume || !player.can_control
                || (dragging_volume && volume_player != player)) {
                return;
            }

            double volume = volume_scale.get_value();
            player.set_player_volume(volume);
        }

        private void on_volume_button_clicked() {
            if (player == null || !player.has_volume || !player.can_control) {
                return;
            }

            player.toggle_mute();
        }

        private double slider_volume(double volume) {
            if (volume < 0.0) {
                return 0.0;
            }
            if (volume > 1.0) {
                return 1.0;
            }

            return volume;
        }

        private void update_volume_button() {
            if (player == null || !player.has_volume || player.volume <= 0.0) {
                volume_icon.icon_name = "audio-volume-muted-symbolic";
                set_control_label(volume_button, _("Restore volume"));
                return;
            }

            set_control_label(volume_button, _("Mute"));
            if (player.volume < 0.35) {
                volume_icon.icon_name = "audio-volume-low-symbolic";
            } else if (player.volume < 0.7) {
                volume_icon.icon_name = "audio-volume-medium-symbolic";
            } else {
                volume_icon.icon_name = "audio-volume-high-symbolic";
            }
        }

        private string format_time(int64 microseconds) {
            int64 total_seconds = microseconds / 1000000;
            int64 minutes = total_seconds / 60;
            int seconds = (int) (total_seconds % 60);

            return ("%" + int64.FORMAT + ":%02d").printf(minutes, seconds);
        }

    }
}
