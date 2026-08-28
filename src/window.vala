namespace MprisMiniPlayer {
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
        private string current_art_url = "";
        private uint artwork_request_id = 0;
        private Soup.Session artwork_session;
        private Cancellable? artwork_cancellable;
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
        private Gtk.MenuButton player_button;
        private Gtk.Image player_icon;
        private Gtk.Label player_label;
        private Gtk.Popover player_popover;
        private Gtk.ListBox player_list;
        private uint position_timeout_id = 0;
        private bool updating_progress = false;
        private bool updating_volume = false;

        public Window(
            Gtk.Application app,
            MprisManager? manager,
            bool compact_mode,
            bool album_tint_enabled
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
            artwork_session = new Soup.Session();

            tint_provider = new Gtk.CssProvider();
            Gtk.StyleContext.add_provider_for_display(
                get_display(),
                tint_provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            );

            build_ui();
            if (manager != null) {
                manager.active_player_changed.connect(sync_active_player);
            }
            set_compact_mode(compact_mode);
            start_position_timer();
            refresh_players();
        }

        public void set_album_tint_enabled(bool enabled) {
            album_tint_enabled = enabled;
            if (!enabled) {
                clear_album_tint();
            } else if (current_artwork_pixbuf != null) {
                apply_album_tint(current_artwork_pixbuf);
            }
        }

        public void refresh_players() {
            if (manager != null) {
                manager.refresh_active_player();
            }
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
            player_button.tooltip_text = _("Choose player");
            player_button.child = player_button_box;
            player_button.halign = Gtk.Align.START;
            player_button.sensitive = false;
            header_bar.pack_start(player_button);

            var menu = new Menu();
            menu.append(_("Compact Mode"), "app.compact-mode");
            menu.append(_("Preferences"), "app.preferences");
            menu.append(_("Quit"), "app.quit");

            var menu_button = new Gtk.MenuButton();
            menu_button.icon_name = "open-menu-symbolic";
            menu_button.tooltip_text = _("Main menu");
            menu_button.menu_model = menu;
            header_bar.pack_end(menu_button);

            var about_button = new Gtk.Button.from_icon_name("help-about-symbolic");
            about_button.tooltip_text = _("About MPRIS MiniPlayer");
            about_button.action_name = "app.about";
            header_bar.pack_end(about_button);

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
            progress_scale.hexpand = true;
            progress_scale.value_changed.connect(on_progress_value_changed);
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
            volume_button.tooltip_text = _("Volume");
            volume_button.clicked.connect(on_volume_button_clicked);
            volume_box.append(volume_button);

            volume_icon = new Gtk.Image.from_icon_name("audio-volume-high-symbolic");
            volume_icon.pixel_size = 16;
            volume_button.child = volume_icon;

            volume_scale = new Gtk.Scale.with_range(Gtk.Orientation.HORIZONTAL, 0, 1, 0.01);
            volume_scale.draw_value = false;
            volume_scale.sensitive = false;
            volume_scale.tooltip_text = _("Volume");
            volume_scale.set_size_request(90, -1);
            volume_scale.value_changed.connect(on_volume_value_changed);
            volume_box.append(volume_scale);

            previous_button = new Gtk.Button.from_icon_name("media-skip-backward-symbolic");
            previous_button.tooltip_text = _("Previous");
            previous_button.clicked.connect(() => {
                if (player != null) {
                    player.previous();
                }
            });
            controls.append(previous_button);

            play_pause_button = new Gtk.Button.from_icon_name("media-playback-start-symbolic");
            play_pause_button.tooltip_text = _("Play or pause");
            play_pause_button.clicked.connect(() => {
                if (player != null) {
                    player.play_pause();
                }
            });
            play_pause_button.add_css_class("suggested-action");
            controls.append(play_pause_button);

            next_button = new Gtk.Button.from_icon_name("media-skip-forward-symbolic");
            next_button.tooltip_text = _("Next");
            next_button.clicked.connect(() => {
                if (player != null) {
                    player.next();
                }
            });
            controls.append(next_button);

            player_popover = new Gtk.Popover();
            player_list = new Gtk.ListBox();
            player_list.selection_mode = Gtk.SelectionMode.NONE;
            player_popover.child = player_list;
            player_button.set_popover(player_popover);

            update_controls(false);
        }

        private void sync_active_player() {
            if (manager == null) {
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

            player = selected_player;
            if (player != null) {
                player_changed_handler_id = player.changed.connect(update_player_state);
                update_player_state();
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
            update_volume();
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
                        close_artwork_stream(stream);
                        throw new IOError.FAILED(
                            "Artwork request returned HTTP status %u".printf(status)
                        );
                    }

                    int64 content_length = message.get_response_headers().get_content_length();
                    if (content_length > MAX_ARTWORK_BYTES) {
                        close_artwork_stream(stream);
                        throw new IOError.MESSAGE_TOO_LARGE(
                            "Album artwork exceeds the %" + int64.FORMAT + " byte limit",
                            MAX_ARTWORK_BYTES
                        );
                    }

                    try {
                        bytes = yield read_artwork_stream(stream, cancellable);
                    } finally {
                        close_artwork_stream(stream);
                    }
                } else {
                    var stream = yield File.new_for_uri(art_url).read_async(
                        Priority.DEFAULT,
                        cancellable
                    );
                    try {
                        bytes = yield read_artwork_stream(stream, cancellable);
                    } finally {
                        close_artwork_stream(stream);
                    }
                }

                if (request_id != artwork_request_id || cancellable.is_cancelled()) {
                    return;
                }

                Gdk.Pixbuf pixbuf = decode_artwork(bytes);
                Gdk.MemoryFormat format = pixbuf.get_has_alpha()
                    ? Gdk.MemoryFormat.R8G8B8A8
                    : Gdk.MemoryFormat.R8G8B8;
                var texture = new Gdk.MemoryTexture(
                    pixbuf.get_width(),
                    pixbuf.get_height(),
                    format,
                    pixbuf.read_pixel_bytes(),
                    (size_t) pixbuf.get_rowstride()
                );
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

        private void close_artwork_stream(InputStream stream) {
            try {
                stream.close();
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

        private void update_controls(bool has_player) {
            previous_button.sensitive = has_player && player.can_go_previous;
            play_pause_button.sensitive = has_player && (player.can_play || player.can_pause);
            next_button.sensitive = has_player && player.can_go_next;
            player_button.sensitive = has_player;
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
                if (
                    manager != null
                    && (player == null || player.bus_name != listed_player.bus_name)
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
            if (updating_progress || player == null || !player.can_seek || player.duration_us <= 0) {
                return;
            }

            int64 position_us = (int64) (progress_scale.get_value() * 1000000.0);
            player.seek_to_position(position_us);
        }

        private void update_volume() {
            bool has_volume = player != null && player.has_volume;
            volume_box.visible = has_volume;

            updating_volume = true;
            volume_scale.set_value(has_volume ? slider_volume(player.volume) : 0);
            updating_volume = false;

            update_volume_button();
        }

        private void on_volume_value_changed() {
            if (updating_volume || player == null || !player.has_volume || !player.can_control) {
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
                volume_button.tooltip_text = _("Restore volume");
                return;
            }

            volume_button.tooltip_text = _("Mute");
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
            int minutes = (int) (total_seconds / 60);
            int seconds = (int) (total_seconds % 60);

            return "%d:%02d".printf(minutes, seconds);
        }

    }
}
