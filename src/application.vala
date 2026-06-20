namespace MprisMiniPlayer {
    public class Application : Adw.Application {
        private Window? main_window;

        public Application() {
            Object(
                application_id: "io.github.ChrisLauinger.MprisMiniPlayer",
                flags: ApplicationFlags.DEFAULT_FLAGS
            );
        }

        protected override void activate() {
            if (main_window == null) {
                main_window = new Window(this);
            }

            main_window.present();
        }
    }
}
