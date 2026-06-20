int main(string[] args) {
    Intl.setlocale(LocaleCategory.ALL, "");
    Intl.bindtextdomain(MprisMiniPlayer.Config.GETTEXT_PACKAGE, MprisMiniPlayer.Config.LOCALEDIR);
    Intl.bind_textdomain_codeset(MprisMiniPlayer.Config.GETTEXT_PACKAGE, "UTF-8");
    Intl.textdomain(MprisMiniPlayer.Config.GETTEXT_PACKAGE);

    var app = new MprisMiniPlayer.Application();
    return app.run(args);
}
