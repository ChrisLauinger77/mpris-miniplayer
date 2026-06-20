namespace MprisMiniPlayer {
    public class Window : Adw.ApplicationWindow {
        private MprisManager? manager;
        private MprisPlayer? player;

        private Gtk.Stack cover_stack;
        private Gtk.Picture cover;
        private Gtk.Image empty_icon;
        private Gtk.Box progress_row;
        private Gtk.Label title_label;
        private Gtk.Label artist_label;
        private Gtk.Label album_label;
        private Gtk.Scale progress_scale;
        private Gtk.Label time_label;
        private Gtk.Button previous_button;
        private Gtk.Button play_pause_button;
        private Gtk.Button next_button;
        private Gtk.MenuButton player_button;
        private Gtk.Image player_icon;
        private Gtk.Label player_label;
        private Gtk.Popover player_popover;
        private Gtk.ListBox player_list;
        private uint position_timeout_id = 0;

        public Window(Gtk.Application app) {
            Object(
                application: app,
                title: _("MPRIS MiniPlayer"),
                default_width: 440,
                default_height: 170
            );

            build_ui();
            start_position_timer();

            try {
                manager = new MprisManager();
                manager.players_changed.connect(select_first_player);
                select_first_player();
            } catch (Error error) {
                show_empty_state("Session D-Bus unavailable", error.message);
            }
        }

        private void build_ui() {
            var toolbar_view = new Adw.ToolbarView();
            set_content(toolbar_view);

            var header_bar = new Adw.HeaderBar();
            header_bar.show_title = false;
            header_bar.set_size_request(-1, 34);
            toolbar_view.add_top_bar(header_bar);

            var box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 14);
            box.margin_top = 8;
            box.margin_bottom = 12;
            box.margin_start = 14;
            box.margin_end = 14;
            toolbar_view.set_content(box);

            cover_stack = new Gtk.Stack();
            cover_stack.set_size_request(108, 108);
            cover_stack.add_css_class("card");
            box.append(cover_stack);

            cover = new Gtk.Picture();
            cover.content_fit = Gtk.ContentFit.COVER;
            cover_stack.add_named(cover, "artwork");

            empty_icon = new Gtk.Image.from_icon_name("multimedia-player-symbolic");
            empty_icon.pixel_size = 42;
            empty_icon.add_css_class("dim-label");
            cover_stack.add_named(empty_icon, "empty");

            var content = new Gtk.Box(Gtk.Orientation.VERTICAL, 5);
            content.hexpand = true;
            box.append(content);

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
            progress_scale.hexpand = true;
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

            previous_button = new Gtk.Button.from_icon_name("media-skip-backward-symbolic");
            previous_button.tooltip_text = _("Previous");
            previous_button.clicked.connect(() => player.previous());
            controls.append(previous_button);

            play_pause_button = new Gtk.Button.from_icon_name("media-playback-start-symbolic");
            play_pause_button.tooltip_text = _("Play or pause");
            play_pause_button.clicked.connect(() => player.play_pause());
            play_pause_button.add_css_class("suggested-action");
            controls.append(play_pause_button);

            next_button = new Gtk.Button.from_icon_name("media-skip-forward-symbolic");
            next_button.tooltip_text = _("Next");
            next_button.clicked.connect(() => player.next());
            controls.append(next_button);

            var player_button_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
            player_icon = new Gtk.Image.from_icon_name("multimedia-player-symbolic");
            player_icon.pixel_size = 16;
            player_button_box.append(player_icon);

            player_label = new Gtk.Label("");
            player_label.halign = Gtk.Align.END;
            player_label.ellipsize = Pango.EllipsizeMode.END;
            player_button_box.append(player_label);

            var chevron = new Gtk.Image.from_icon_name("pan-down-symbolic");
            chevron.pixel_size = 12;
            player_button_box.append(chevron);

            player_button = new Gtk.MenuButton();
            player_button.tooltip_text = _("Choose player");
            player_button.child = player_button_box;
            player_button.hexpand = true;
            player_button.halign = Gtk.Align.END;
            player_button.sensitive = false;
            controls.append(player_button);

            player_popover = new Gtk.Popover();
            player_list = new Gtk.ListBox();
            player_list.selection_mode = Gtk.SelectionMode.NONE;
            player_popover.child = player_list;
            player_button.set_popover(player_popover);

            update_controls(false);
        }

        private void select_first_player() {
            if (manager == null) {
                return;
            }

            string[] players = manager.list_players();
            rebuild_player_list(players);

            if (players.length == 0) {
                player = null;
                show_empty_state(_("No player detected"), _("Start any MPRIS-compatible player"));
                return;
            }

            string selected_bus_name = players[0];
            if (player != null && has_player(players, player.bus_name)) {
                selected_bus_name = player.bus_name;
            }

            if (player != null && player.bus_name == selected_bus_name) {
                player.refresh();
                return;
            }

            select_player(selected_bus_name);
        }

        private void select_player(string bus_name) {
            try {
                player = new MprisPlayer(bus_name);
                player.changed.connect(update_player_state);
                update_player_state();
                if (manager != null) {
                    rebuild_player_list(manager.list_players());
                }
            } catch (Error error) {
                warning("Unable to select player %s: %s", bus_name, error.message);
                show_empty_state(_("Player unavailable"), error.message);
            }
        }

        private void update_player_state() {
            if (player == null) {
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
            update_controls(true);

            if (player.playback_status == "Playing") {
                play_pause_button.icon_name = "media-playback-pause-symbolic";
            } else {
                play_pause_button.icon_name = "media-playback-start-symbolic";
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
            progress_row.visible = false;
            progress_scale.set_value(0);
            time_label.label = "0:00 / 0:00";
            update_controls(false);
        }

        private void set_artwork(string art_url) {
            if (art_url == "") {
                cover.paintable = null;
                cover_stack.visible_child_name = "empty";
                return;
            }

            var file = File.new_for_uri(art_url);
            cover.set_file(file);
            cover_stack.visible_child_name = "artwork";
        }

        private void set_label_with_tooltip(Gtk.Label label, string text) {
            label.label = text;
            label.tooltip_text = text == "" ? null : text;
        }

        private void update_controls(bool has_player) {
            previous_button.sensitive = has_player && player.can_go_previous;
            play_pause_button.sensitive = has_player && (player.can_play || player.can_pause);
            next_button.sensitive = has_player && player.can_go_next;
            player_button.sensitive = has_player;
        }

        private void rebuild_player_list(string[] bus_names) {
            Gtk.Widget? row = player_list.get_first_child();
            while (row != null) {
                Gtk.Widget next = row.get_next_sibling();
                player_list.remove(row);
                row = next;
            }

            foreach (var bus_name in bus_names) {
                try {
                    var listed_player = new MprisPlayer(bus_name);
                    player_list.append(create_player_row(listed_player));
                } catch (Error error) {
                    warning("Unable to list player %s: %s", bus_name, error.message);
                }
            }
        }

        private Gtk.Widget create_player_row(MprisPlayer listed_player) {
            var button = new Gtk.Button();
            button.has_frame = false;
            button.hexpand = true;
            button.clicked.connect(() => {
                player_popover.popdown();
                if (player == null || player.bus_name != listed_player.bus_name) {
                    select_player(listed_player.bus_name);
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

        private bool has_player(string[] bus_names, string bus_name) {
            foreach (var candidate in bus_names) {
                if (candidate == bus_name) {
                    return true;
                }
            }

            return false;
        }

        private void start_position_timer() {
            if (position_timeout_id != 0) {
                return;
            }

            position_timeout_id = Timeout.add_seconds(1, () => {
                if (player != null) {
                    if (player.playback_status == "Playing") {
                        player.refresh_position();
                    }
                    update_progress();
                }

                return Source.CONTINUE;
            });
        }

        private void update_progress() {
            if (player == null || player.duration_us <= 0) {
                progress_scale.set_range(0, 1);
                progress_scale.set_value(0);
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

            progress_scale.set_range(0, duration_seconds);
            progress_scale.set_value(position_seconds);
            time_label.label = "%s / %s".printf(
                format_time(player.position_us),
                format_time(player.duration_us)
            );
        }

        private string format_time(int64 microseconds) {
            int64 total_seconds = microseconds / 1000000;
            int minutes = (int) (total_seconds / 60);
            int seconds = (int) (total_seconds % 60);

            return "%d:%02d".printf(minutes, seconds);
        }
    }
}
