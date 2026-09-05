namespace MprisMiniPlayer {
    // Owns one source, one request, and at most two retries. No historical cache.
    public class ArtworkLoader : Object {
        private const int64 MAX_ARTWORK_BYTES = 10 * 1024 * 1024;
        private const int MAX_ARTWORK_DIMENSION = 8192;
        private const int64 MAX_ARTWORK_PIXELS = 16 * 1024 * 1024;
        private const int ARTWORK_DECODE_SIZE = 256;
        private const size_t ARTWORK_READ_CHUNK_BYTES = 64 * 1024;
        private const uint ARTWORK_TIMEOUT_SECONDS = 15;

        private string source_key = "";
        private string current_art_url = "";
        private uint artwork_request_id = 0;
        private Soup.Session artwork_session = new Soup.Session();
        private Cancellable? artwork_cancellable;
        private FileMonitor? monitor;
        private uint retry_source;
        private uint reload_source;
        private uint attempts;
        private bool stopped = false;
        private bool loaded = false;

        public signal void changed(Gdk.Pixbuf? pixbuf);
        public signal void failed(Error error);

        public void set_source(string key, string url) {
            if (stopped || (source_key == key && current_art_url == url)) return;
            clear_source();
            source_key = key;
            current_art_url = url;
            attempts = 0;
            loaded = false;
            uint version = artwork_request_id;
            changed(null);
            if (stopped || version != artwork_request_id) return;
            if (url == "") return;
            if (Uri.parse_scheme(url) == "file") {
                try {
                    monitor = File.new_for_uri(url).monitor_file(FileMonitorFlags.NONE);
                    monitor.changed.connect(() => {
                        if (reload_source != 0) return;
                        reload_source = Timeout.add(200, () => {
                            reload_source = 0;
                            attempts = 0;
                            begin_load();
                            return Source.REMOVE;
                        });
                    });
                } catch (Error error) {
                    debug("Unable to monitor artwork: %s", error.message);
                }
            }
            begin_load();
        }

        // Reopening the window may retry an exhausted failure without polling.
        public void retry() {
            if (stopped || loaded || artwork_cancellable != null || retry_source != 0) return;
            attempts = 0;
            begin_load();
        }

        private void begin_load() {
            if (stopped || current_art_url == "") return;
            if (retry_source != 0) { Source.remove(retry_source); retry_source = 0; }
            cancel_artwork_request();
            attempts++;
            artwork_cancellable = new Cancellable();
            load_artwork.begin(current_art_url, ++artwork_request_id, artwork_cancellable);
        }

        private void clear_source() {
            artwork_request_id++;
            cancel_artwork_request();
            if (retry_source != 0) { Source.remove(retry_source); retry_source = 0; }
            if (reload_source != 0) { Source.remove(reload_source); reload_source = 0; }
            if (monitor != null) { monitor.cancel(); monitor = null; }
        }

        public void shutdown() {
            if (stopped) return;
            stopped = true;
            clear_source();
            artwork_session.abort();
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
                        yield close_artwork_stream(stream);
                        throw new IOError.FAILED(
                            "Artwork request returned HTTP status %u".printf(status)
                        );
                    }

                    int64 content_length = message.get_response_headers().get_content_length();
                    if (content_length > MAX_ARTWORK_BYTES) {
                        yield close_artwork_stream(stream);
                        throw new IOError.MESSAGE_TOO_LARGE(
                            "Album artwork exceeds the %" + int64.FORMAT + " byte limit",
                            MAX_ARTWORK_BYTES
                        );
                    }

                    try {
                        bytes = yield read_artwork_stream(stream, cancellable);
                    } finally {
                        yield close_artwork_stream(stream);
                    }
                } else {
                    var stream = yield File.new_for_uri(art_url).read_async(
                        Priority.DEFAULT,
                        cancellable
                    );
                    try {
                        bytes = yield read_artwork_stream(stream, cancellable);
                    } finally {
                        yield close_artwork_stream(stream);
                    }
                }

                if (stopped || request_id != artwork_request_id || cancellable.is_cancelled()) {
                    return;
                }

                Gdk.Pixbuf pixbuf = decode_artwork(bytes);
                if (stopped || request_id != artwork_request_id || cancellable.is_cancelled()) return;
                artwork_cancellable = null;
                loaded = true;
                changed(pixbuf);
            } catch (Error error) {
                if (!stopped && request_id == artwork_request_id) {
                    artwork_cancellable = null;
                    loaded = false;
                    changed(null);
                    debug("Unable to load album artwork: %s", error.message);
                    if (stopped || request_id != artwork_request_id) return;
                    failed(error);
                    if (!stopped && request_id == artwork_request_id && attempts < 3) {
                        retry_source = Timeout.add_seconds(attempts * attempts, () => {
                            retry_source = 0;
                            begin_load();
                            return Source.REMOVE;
                        });
                    }
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

        private async void close_artwork_stream(InputStream stream) {
            // Cleanup must not inherit an already-cancelled read request, but a
            // remote GIO backend must not retain us indefinitely while closing.
            var cancellable = new Cancellable();
            uint timeout = 0;
            timeout = Timeout.add_seconds(3, () => {
                timeout = 0;
                cancellable.cancel();
                return Source.REMOVE;
            });
            try {
                yield stream.close_async(Priority.DEFAULT, cancellable);
            } catch (Error error) {
                debug("Unable to close album artwork stream: %s", error.message);
            } finally {
                if (timeout != 0) Source.remove(timeout);
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

        internal Gdk.Pixbuf decode_artwork(Bytes bytes) throws Error {
            validate_static_artwork(bytes);

            var loader = new Gdk.PixbufLoader();
            bool dimensions_ready = false;
            bool dimensions_valid = false;

            ulong size_handler = loader.size_prepared.connect((width, height) => {
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

            bool closed = false;
            try {
                loader.write_bytes(bytes);
                loader.close();
                closed = true;
            } finally {
                // The closure owns loader; disconnect on failure as well as success.
                SignalHandler.disconnect(loader, size_handler);
                try {
                    if (!closed) loader.close();
                } catch (Error error) {
                    debug("Unable to close artwork decoder: %s", error.message);
                }
            }
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

    }
}
