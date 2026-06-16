#!/usr/bin/env python3
"""
exam-kiosk.py  —  Browser kiosk per esami
Rocky Linux / Cinnamon X11  —  nessun root richiesto

Avvio:  python3 exam-kiosk.py
Fine:   Ctrl+C nel terminale (o chiudi la finestra se sei il docente)

Dipendenze già presenti sul sistema:
  python3-gobject, webkit2gtk3 (GTK3 + WebKit2 4.0)
"""

import sys, os, signal, subprocess, threading, atexit, datetime

try:
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("WebKit2", "4.0")
    from gi.repository import Gtk, WebKit2, Gdk, GLib
except ImportError:
    sys.exit(42)

# ═══════════════════════════════════════════════════════════════
#  URL: passato come argv[1] da update.sh (con token dinamico).
#  Fallback all'URL hardcoded se lanciato manualmente senza argomenti.
# ═══════════════════════════════════════════════════════════════
JUPYTER_URL = (
    sys.argv[1]
    if len(sys.argv) > 1
    else "http://127.0.0.1:8888/lab"
)
EXAM_URL   = "https://esami.unipd.it/"
README_URL = sys.argv[2] if len(sys.argv) > 2 else ""
# ═══════════════════════════════════════════════════════════════


# ═══════════════════════════════════════════════════════════════
#  LOCKDOWN DI SISTEMA
#  gsettings  → disabilita scorciatoie Cinnamon/WM
#  setxkbmap  → blocca cambio VT (Ctrl+Alt+F1-F12)
#  xmodmap    → rimuove il tasto Super dal modificatore Mod4
#               (watchdog lo ri-applica ogni 2s se il settings
#                daemon di Cinnamon reimposta il keymap)
# ═══════════════════════════════════════════════════════════════
class SystemLockdown:
    def __init__(self):
        self._bindings: list[tuple[str, str, str]] = []
        self._old_xkb: str = ""
        self._old_super: list[str] = []
        self._stop_wd = threading.Event()
        self._watchdog: threading.Thread | None = None
        self._restored = False

    # ── gsettings ──────────────────────────────────────────────
    def _save_clear(self, schema: str, key: str):
        try:
            val = (
                subprocess.check_output(
                    ["gsettings", "get", schema, key], stderr=subprocess.DEVNULL
                )
                .decode()
                .strip()
            )
            self._bindings.append((schema, key, val))
            subprocess.run(
                ["gsettings", "set", schema, key, "[]"], stderr=subprocess.DEVNULL
            )
        except Exception:
            pass  # schema/chiave non presente su questa versione di Cinnamon

    def _disable_shortcuts(self):
        WM = "org.cinnamon.desktop.keybindings.wm"
        CK = "org.cinnamon.desktop.keybindings"
        MK = "org.gnome.settings-daemon.plugins.media-keys"
        GWM = "org.gnome.desktop.wm.keybindings"  # Muffin legge anche questo

        # Cambio workspace — svuota in entrambi gli schema
        for k in [
            "switch-to-workspace-left",
            "switch-to-workspace-right",
            "switch-to-workspace-up",
            "switch-to-workspace-down",
            "switch-to-workspace-1",
            "switch-to-workspace-2",
            "switch-to-workspace-3",
            "switch-to-workspace-4",
            "move-to-workspace-left",
            "move-to-workspace-right",
            "move-to-workspace-up",
            "move-to-workspace-down",
        ]:
            self._save_clear(WM, k)
            self._save_clear(GWM, k)

        # Gestione finestre
        for k in [
            "switch-windows",
            "switch-windows-backward",
            "switch-group",
            "switch-group-backward",
            "show-desktop",
            "panel-run-dialog",
            "begin-move",
            "begin-resize",
        ]:
            self._save_clear(WM, k)
            self._save_clear(GWM, k)

        # Shell Cinnamon (menu, expo, desklet)
        for k in [
            "panel-main-menu",
            "panel-run-dialog",
            "toggle-overview",
            "show-desklets",
            "expo",
        ]:
            self._save_clear(CK, k)

        # Azzera TUTTE le scorciatoie personalizzate (Ctrl+Alt+T, ecc.)
        self._save_clear(CK, "custom-list")

        # Tasti multimediali che aprono applicazioni
        for k in ["terminal", "home", "calculator", "www", "email"]:
            self._save_clear(MK, k)

        print("[kiosk] Scorciatoie Cinnamon sospese.")

    # ── setxkbmap ──────────────────────────────────────────────
    def _block_vt_switch(self):
        try:
            out = subprocess.check_output(
                ["setxkbmap", "-query"], stderr=subprocess.DEVNULL
            ).decode()
            for line in out.splitlines():
                if line.startswith("options"):
                    self._old_xkb = line.split(":", 1)[1].strip()
            subprocess.run(
                ["setxkbmap", "-option", "srvrkeys:none"], stderr=subprocess.DEVNULL
            )
            print("[kiosk] Cambio VT (Ctrl+Alt+F1…F12) bloccato.")
        except Exception:
            print("[kiosk] Avviso: setxkbmap non disponibile.")

    # ── xmodmap + watchdog ─────────────────────────────────────
    def _apply_super_disable(self):
        for cmd in [
            "remove mod4 = Super_L Super_R",
            "keycode 133 =",
            "keycode 134 =",
        ]:
            subprocess.run(["xmodmap", "-e", cmd], stderr=subprocess.DEVNULL)

    def _disable_super(self):
        try:
            out = subprocess.check_output(
                ["xmodmap", "-pke"], stderr=subprocess.DEVNULL
            ).decode()
            self._old_super = [
                l for l in out.splitlines() if "keycode 133" in l or "keycode 134" in l
            ]
        except Exception:
            pass

        self._apply_super_disable()

        def _wd():
            while not self._stop_wd.wait(2):
                self._apply_super_disable()

        self._watchdog = threading.Thread(target=_wd, daemon=True, name="super-wd")
        self._watchdog.start()
        print("[kiosk] Tasto Super disabilitato (watchdog attivo).")

    # ── Applica tutto ──────────────────────────────────────────
    def apply(self):
        self._disable_shortcuts()
        self._block_vt_switch()  # PRIMA di xmodmap: setxkbmap resetta il keymap
        self._disable_super()  # DOPO setxkbmap

    # ── Ripristina tutto ───────────────────────────────────────
    def restore(self):
        if self._restored:
            return
        self._restored = True
        print("[kiosk] Ripristino impostazioni di sistema...")

        self._stop_wd.set()
        if self._watchdog:
            self._watchdog.join(timeout=3)

        for schema, key, val in self._bindings:
            subprocess.run(
                ["gsettings", "set", schema, key, val], stderr=subprocess.DEVNULL
            )

        # setxkbmap ripristina anche i keysym (incluso Super_L)
        if self._old_xkb:
            subprocess.run(
                ["setxkbmap", "-option", self._old_xkb], stderr=subprocess.DEVNULL
            )
        else:
            subprocess.run(["setxkbmap", "-option"], stderr=subprocess.DEVNULL)

        # xmodmap belt-and-suspenders
        for line in self._old_super:
            subprocess.run(["xmodmap", "-e", line], stderr=subprocess.DEVNULL)
        if self._old_super:
            subprocess.run(
                ["xmodmap", "-e", "add mod4 = Super_L Super_R"],
                stderr=subprocess.DEVNULL,
            )


# ═══════════════════════════════════════════════════════════════
#  WEBKIT2 — POLICY (no new windows, no URL filtering)
# ═══════════════════════════════════════════════════════════════
def _on_decide_policy(wv, decision, dtype):
    NEW = WebKit2.PolicyDecisionType.NEW_WINDOW_ACTION
    if dtype == NEW:
        # Redirect target="_blank" links into the same tab
        uri = decision.get_navigation_action().get_request().get_uri()
        wv.load_uri(uri)
        decision.ignore()
        return True
    return False


def _on_create(wv, nav_action):
    """Redirect window.open() into the same tab instead of a new window."""
    uri = nav_action.get_request().get_uri()
    wv.load_uri(uri)
    return None


def _on_context_menu(wv, menu, event, hit_test):
    """Disabilita il menu contestuale del tasto destro."""
    return True


def _make_webview(context: WebKit2.WebContext) -> WebKit2.WebView:
    s = WebKit2.Settings()
    s.set_enable_developer_extras(False)  # niente DevTools (F12)
    s.set_javascript_can_open_windows_automatically(False)
    s.set_allow_file_access_from_file_urls(False)
    s.set_enable_page_cache(False)
    s.set_enable_write_console_messages_to_stdout(False)
    # Lascia abilitati upload di file (necessari per la consegna)
    # e JavaScript (necessario per Jupyter)

    wv = WebKit2.WebView.new_with_context(context)
    wv.set_settings(s)
    wv.connect("decide-policy", _on_decide_policy)
    wv.connect("create", _on_create)
    wv.connect("context-menu", _on_context_menu)
    return wv


# ═══════════════════════════════════════════════════════════════
#  FINESTRA KIOSK
# ═══════════════════════════════════════════════════════════════
class KioskWindow(Gtk.Window):
    def __init__(self, context: WebKit2.WebContext):
        super().__init__()
        self.set_title("Sessione d'Esame")
        self.set_decorated(False)  # niente barra del titolo
        self.fullscreen()

        # Alt+F4 / pulsante WM → stessa conferma del bottone Esci
        self.connect("delete-event", lambda w, e: self._confirm_exit() or True)
        self.connect("key-press-event", self._on_key)

        # Stile: tab grandi + bottone Esci rosso
        css = Gtk.CssProvider()
        css.load_from_data(b"""
            notebook tab {
                padding: 8px 28px;
                font-size: 13pt;
                font-weight: bold;
            }
            box.header-bar {
                background-color: #2c2c2c;
                min-height: 40px;
            }
            label.clock-label {
                color: white;
                font-size: 13pt;
                font-weight: bold;
                font-family: monospace;
            }
            button.exit-btn {
                background-color: #c0392b;
                color: white;
                font-weight: bold;
                font-size: 11pt;
                border: none;
                border-radius: 4px;
                padding: 4px 16px;
            }
            button.exit-btn:hover {
                background-color: #e74c3c;
            }
        """)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        # Layout: header (tab bar + bottone) sopra, notebook sotto
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(root)

        # ── Header bar ────────────────────────────────────────────
        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        header.get_style_context().add_class("header-bar")

        # Bottone Esci, ancorato a destra
        exit_btn = Gtk.Button(label=" ✕  Fine sessione ")
        exit_btn.get_style_context().add_class("exit-btn")
        exit_btn.connect("clicked", lambda b: self._confirm_exit())
        exit_btn.set_valign(Gtk.Align.CENTER)

        # Orologio, ancorato a sinistra
        self._clock_label = Gtk.Label()
        self._clock_label.get_style_context().add_class("clock-label")
        self._clock_label.set_valign(Gtk.Align.CENTER)
        self._update_clock()
        GLib.timeout_add_seconds(1, self._update_clock)

        header.pack_start(self._clock_label, expand=False, fill=False, padding=12)
        header.pack_end(exit_btn, expand=False, fill=False, padding=8)
        root.pack_start(header, expand=False, fill=False, padding=0)

        # ── Notebook (occupa tutto lo spazio restante) ─────────────
        nb = Gtk.Notebook()
        nb.set_show_border(False)
        root.pack_start(nb, expand=True, fill=True, padding=0)

        wv1 = _make_webview(context)
        wv1.load_uri(JUPYTER_URL)
        nb.append_page(wv1, Gtk.Label(label="  Jupyter Notebook  "))

        wv2 = _make_webview(context)
        wv2.load_uri(EXAM_URL)
        nb.append_page(wv2, Gtk.Label(label="  Exam Upload  "))

        if README_URL:
            wv3 = _make_webview(context)
            wv3.load_uri(README_URL)
            nb.append_page(wv3, Gtk.Label(label="  Istruzioni  "))

        self.show_all()

    def _confirm_exit(self):
        """Mostra un dialogo di conferma prima di uscire."""
        dlg = Gtk.MessageDialog(
            transient_for=self,
            modal=True,
            message_type=Gtk.MessageType.QUESTION,
            buttons=Gtk.ButtonsType.NONE,
            text="Vuoi terminare la sessione d'esame?",
        )
        dlg.format_secondary_text(
            "Assicurati di aver salvato il tuo lavoro e caricato i file\n"
            "sulla piattaforma prima di uscire."
        )
        dlg.add_button("Annulla", Gtk.ResponseType.CANCEL)
        dlg.add_button("Esci dalla sessione", Gtk.ResponseType.YES)
        dlg.set_default_response(Gtk.ResponseType.CANCEL)

        # Stile tasto di conferma in rosso
        yes_btn = dlg.get_widget_for_response(Gtk.ResponseType.YES)
        if yes_btn:
            yes_btn.get_style_context().add_class("destructive-action")

        resp = dlg.run()
        dlg.destroy()
        if resp == Gtk.ResponseType.YES:
            Gtk.main_quit()

    def _on_key(self, win, ev) -> bool:
        """Blocca scorciatoie per DevTools e visualizzazione sorgente."""
        ctrl = bool(ev.state & Gdk.ModifierType.CONTROL_MASK)
        shift = bool(ev.state & Gdk.ModifierType.SHIFT_MASK)
        k = ev.keyval

        if k == Gdk.KEY_F12:
            return True  # DevTools
        if ctrl and shift and k in (Gdk.KEY_i, Gdk.KEY_j):  # Ctrl+Shift+I/J
            return True
        if ctrl and k == Gdk.KEY_u:  # View Source
            return True
        return False

    def _update_clock(self) -> bool:
        self._clock_label.set_text(datetime.datetime.now().strftime("  %H:%M:%S  "))
        return True  # keep GLib timer running


# ═══════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════
def main():
    lockdown = SystemLockdown()
    lockdown.apply()
    atexit.register(lockdown.restore)

    # SIGTERM e SIGINT → esci dal loop GTK → atexit ripristina tutto
    def _quit(sig, frame):
        GLib.idle_add(Gtk.main_quit)

    signal.signal(signal.SIGTERM, _quit)
    signal.signal(signal.SIGINT, _quit)

    # Contesto effimero: nessun dato (cookie, cache) persiste su disco
    context = WebKit2.WebContext.new_ephemeral()

    win = KioskWindow(context)
    Gtk.main()


if __name__ == "__main__":
    main()
