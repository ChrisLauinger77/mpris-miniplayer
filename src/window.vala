namespace MprisMiniPlayer {
    public class Window : Adw.ApplicationWindow {
        private MprisManager? manager;
        private MprisPlayer? player;

        private Gtk.Picture cover;
        private Gtk.Label title_label;
        private Gtk.Label artist_label;
        private Gtk.Label album_label;
        private Gtk.Label player_label;
        private Gtk.Button previous_button;
        private Gtk.Button play_pause_button;
        private Gtk.Button next_button;

        public Window(Gtk.Application app) {
            Object(
                application: app,
                title: "MPRIS MiniPlayer",
                default_width: 440,
                default_height: 170
            );

            build_ui();

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
            toolbar_view.add_top_bar(header_bar);

            var box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 16);
            box.margin_top = 16;
            box.margin_bottom = 16;
            box.margin_start = 16;
            box.margin_end = 16;
            toolbar_view.set_content(box);

            cover = new Gtk.Picture();
            cover.set_size_request(120, 120);
            cover.content_fit = Gtk.ContentFit.COVER;
            cover.add_css_class("card");
            box.append(cover);

            var content = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
            content.hexpand = true;
            box.append(content);

            title_label = new Gtk.Label("No player running");
            title_label.halign = Gtk.Align.START;
            title_label.ellipsize = Pango.EllipsizeMode.END;
            title_label.add_css_class("title-2");
            content.append(title_label);

            artist_label = new Gtk.Label("Start an MPRIS-compatible media player");
            artist_label.halign = Gtk.Align.START;
            artist_label.ellipsize = Pango.EllipsizeMode.END;
            artist_label.add_css_class("dim-label");
            content.append(artist_label);

            album_label = new Gtk.Label("");
            album_label.halign = Gtk.Align.START;
            album_label.ellipsize = Pango.EllipsizeMode.END;
            album_label.add_css_class("dim-label");
            content.append(album_label);

            var spacer = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            spacer.vexpand = true;
            content.append(spacer);

            var controls = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            controls.valign = Gtk.Align.END;
            content.append(controls);

            previous_button = new Gtk.Button.from_icon_name("media-skip-backward-symbolic");
            previous_button.tooltip_text = "Previous";
            previous_button.clicked.connect(() => player.previous());
            controls.append(previous_button);

            play_pause_button = new Gtk.Button.from_icon_name("media-playback-start-symbolic");
            play_pause_button.tooltip_text = "Play or pause";
            play_pause_button.clicked.connect(() => player.play_pause());
            play_pause_button.add_css_class("suggested-action");
            controls.append(play_pause_button);

            next_button = new Gtk.Button.from_icon_name("media-skip-forward-symbolic");
            next_button.tooltip_text = "Next";
            next_button.clicked.connect(() => player.next());
            controls.append(next_button);

            player_label = new Gtk.Label("");
            player_label.halign = Gtk.Align.END;
            player_label.hexpand = true;
            player_label.ellipsize = Pango.EllipsizeMode.END;
            controls.append(player_label);

            update_controls(false);
        }

        private void select_first_player() {
            if (manager == null) {
                return;
            }

            string[] players = manager.list_players();
            if (players.length == 0) {
                player = null;
                show_empty_state("No player running", "Start an MPRIS-compatible media player");
                return;
            }

            if (player != null && player.bus_name == players[0]) {
                player.refresh();
                return;
            }

            try {
                player = new MprisPlayer(players[0]);
                player.changed.connect(update_player_state);
                update_player_state();
            } catch (Error error) {
                warning("Unable to select player %s: %s", players[0], error.message);
                show_empty_state("Player unavailable", error.message);
            }
        }

        private void update_player_state() {
            if (player == null) {
                return;
            }

            title_label.label = player.title;
            artist_label.label = player.artist;
            album_label.label = player.album;
            player_label.label = player.display_name();
            set_artwork(player.art_url);
            update_controls(true);

            if (player.playback_status == "Playing") {
                play_pause_button.icon_name = "media-playback-pause-symbolic";
            } else {
                play_pause_button.icon_name = "media-playback-start-symbolic";
            }
        }

        private void show_empty_state(string title, string subtitle) {
            title_label.label = title;
            artist_label.label = subtitle;
            album_label.label = "";
            player_label.label = "";
            cover.paintable = null;
            update_controls(false);
        }

        private void set_artwork(string art_url) {
            if (art_url == "") {
                cover.paintable = null;
                return;
            }

            var file = File.new_for_uri(art_url);
            cover.set_file(file);
        }

        private void update_controls(bool has_player) {
            previous_button.sensitive = has_player && player.can_go_previous;
            play_pause_button.sensitive = has_player && (player.can_play || player.can_pause);
            next_button.sensitive = has_player && player.can_go_next;
        }
    }
}
