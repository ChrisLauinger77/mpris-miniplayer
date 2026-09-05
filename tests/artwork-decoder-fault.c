/* Inject failure after PixbufLoader construction, before any decoder backend
 * starts. This exercises the real cleanup path without a display or helper bus. */
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <gio/gio.h>
static int live;
GdkPixbufLoader *__real_gdk_pixbuf_loader_new(void);
static void finalized(gpointer data, GObject *object) { live--; }
GdkPixbufLoader *__wrap_gdk_pixbuf_loader_new(void) {
    GdkPixbufLoader *loader = __real_gdk_pixbuf_loader_new();
    live++;
    g_object_weak_ref(G_OBJECT(loader), finalized, NULL);
    return loader;
}
gboolean __wrap_gdk_pixbuf_loader_write_bytes(GdkPixbufLoader *loader,
                                              GBytes *bytes, GError **error) {
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, "Injected decoder failure");
    return FALSE;
}
int test_live_decoders(void) { return live; }
