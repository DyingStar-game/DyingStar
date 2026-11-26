"""DyingStar ▸ Publication ▸ Journal de publication: <planet>_chunks/publish.log, followed live.

An export hands its pack to publish_remote.py, which runs detached from QGIS (it survives QGIS
being closed) and appends to that file: one block per publication, opened by a
"--- <time> <file>" line. The panel shows the last block (or the whole file), and the plugin
tells in the message bar when a publication starts and how it ends — the export itself is long
finished by then.
"""
import os
import time

LOG_FILE = "publish.log"
LOCK_FILE = ".publish.lock"
#: Only the end of a long journal is read.
TAIL_BYTES = 256 * 1024

RUNNING, DONE, NOTHING, FAILED, STOPPED = "running", "done", "nothing", "failed", "stopped"
STATE_TEXT = {
    RUNNING: "en cours…",
    DONE: "publié",
    NOTHING: "déjà publié, rien à faire",
    FAILED: "ÉCHEC",
    STOPPED: "interrompue (le processus s'est arrêté sans conclure)",
}


# ── pure helpers (tested without QGIS) ────────────────────────────────────────
def chunks_dir(export_dir, planet):
    return os.path.join(export_dir, f"{planet}_chunks")


def read_tail(path, limit=TAIL_BYTES):
    """The end of [path] (whole lines), "" when absent."""
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - limit))
            data = fh.read()
    except OSError:
        return ""
    text = data.decode("utf-8", errors="replace")
    if size > limit:
        text = text.split("\n", 1)[-1]
    return text


def blocks(text):
    """[(header, body)] — one per publication, in order."""
    out = []
    for chunk in ("\n" + text).split("\n--- ")[1:]:
        header, _, body = chunk.partition("\n")
        out.append(("--- " + header, body))
    return out


def block_state(body, running):
    """What a publication block says: its conclusion, else running / stopped by the lock."""
    for line in reversed(body.splitlines()):
        s = line.strip()
        if s.startswith("== publié"):
            return DONE
        if s.startswith("ERREUR") or s.startswith("Traceback"):
            return FAILED
        if "rien à faire" in s or s.startswith("publish_remote : aucune cible"):
            return NOTHING
    return RUNNING if running else STOPPED


def published_line(body):
    for line in body.splitlines():
        if line.strip().startswith("== publié"):
            return line.strip().lstrip("= ").strip()
    return ""


def is_running(cdir):
    """A publication holds the folder's lock (publish_remote._locked) for its whole run."""
    path = os.path.join(cdir, LOCK_FILE)
    if not os.path.exists(path):
        return False
    try:
        import fcntl
    except ImportError:   # Windows: no lock to probe, trust the journal
        return True
    try:
        with open(path, "a") as fh:
            try:
                fcntl.flock(fh, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except OSError:
                return True
            fcntl.flock(fh, fcntl.LOCK_UN)
    except OSError:
        return False
    return False


#: The journal's header is written just BEFORE the publication starts and takes the lock: a
#: block without a conclusion this fresh is starting, not stopped.
START_GRACE_S = 15.0


def running_now(cdir, now=None):
    if is_running(cdir):
        return True
    try:
        age = (time.time() if now is None else now) - os.stat(os.path.join(cdir, LOG_FILE)).st_mtime
    except OSError:
        return False
    return age < START_GRACE_S


def status(cdir):
    """(state or None, header, body) of the last publication of the folder."""
    text = read_tail(os.path.join(cdir, LOG_FILE))
    bl = blocks(text)
    if not bl:
        return None, "", ""
    header, body = bl[-1]
    return block_state(body, running_now(cdir)), header, body


# ── QGIS side ─────────────────────────────────────────────────────────────────
def _current_dir():
    """<export>/<planet>_chunks of the open planet project, or None."""
    try:
        import ds_project
        import link_modifiers
        return chunks_dir(link_modifiers.resolve_export_dir(), ds_project.planet().name)
    except Exception:  # noqa: BLE001 — not a planet project, no export dir yet
        return None


def _make_dock_class():
    from qgis.PyQt.QtCore import QTimer, QUrl
    from qgis.PyQt.QtGui import QDesktopServices, QFontDatabase, QTextCursor
    from qgis.PyQt.QtWidgets import (QCheckBox, QDockWidget, QHBoxLayout, QLabel,
                                     QPlainTextEdit, QPushButton, QVBoxLayout, QWidget)

    class PublishLogDock(QDockWidget):
        def __init__(self, parent=None):
            super().__init__("DyingStar — journal de publication", parent)
            self.setObjectName("DyingStarPublishLogDock")
            self.cdir = None
            self._sig = None
            body = QWidget()
            self.state = QLabel()
            self.state.setWordWrap(True)
            self.text = QPlainTextEdit()
            self.text.setReadOnly(True)
            self.text.setFont(QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont))
            self.text.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)
            self.whole = QCheckBox("Tout le journal")
            self.whole.setToolTip("Toutes les publications de cette planète, pas seulement "
                                  "la dernière.")
            self.whole.toggled.connect(lambda _on: self.refresh(force=True))
            open_btn = QPushButton("Ouvrir le fichier")
            open_btn.clicked.connect(self._open_file)
            row = QHBoxLayout()
            row.addWidget(self.whole)
            row.addStretch(1)
            row.addWidget(open_btn)
            lay = QVBoxLayout(body)
            lay.setContentsMargins(4, 4, 4, 4)
            lay.addWidget(self.state)
            lay.addWidget(self.text, 1)
            lay.addLayout(row)
            self.setWidget(body)
            self.timer = QTimer(self)
            self.timer.setInterval(1000)
            self.timer.timeout.connect(self.refresh)

        def showEvent(self, event):  # noqa: N802 — Qt
            super().showEvent(event)
            self.refresh(force=True)
            self.timer.start()

        def hideEvent(self, event):  # noqa: N802 — Qt
            self.timer.stop()
            super().hideEvent(event)

        def _open_file(self):
            if self.cdir:
                QDesktopServices.openUrl(QUrl.fromLocalFile(os.path.join(self.cdir, LOG_FILE)))

        def refresh(self, force=False):
            self.cdir = _current_dir()
            if self.cdir is None:
                self.state.setText("Ouvre un projet planète (DyingStar ▸ Projet planète…).")
                self.text.clear()
                self._sig = None
                return
            path = os.path.join(self.cdir, LOG_FILE)
            try:
                st = os.stat(path)
                sig = (path, st.st_size, st.st_mtime_ns, self.whole.isChecked())
            except OSError:
                sig = (path, None, None, self.whole.isChecked())
            running = running_now(self.cdir)
            if sig == self._sig and not force and not running:
                return
            self._sig = sig
            text = read_tail(path)
            bl = blocks(text)
            if not bl:
                self.state.setText(f"Aucune publication dans {path}.")
                self.text.setPlainText(text)
                return
            header, body = bl[-1]
            state = block_state(body, running)
            self.state.setText(f"<b>{STATE_TEXT[state]}</b> — dernière publication : "
                               f"{header[4:]}")
            shown = text if self.whole.isChecked() else header + "\n" + body
            if shown != self.text.toPlainText():
                bar = self.text.verticalScrollBar()
                at_end = bar.value() >= bar.maximum() - 2
                self.text.setPlainText(shown)
                if at_end or force:
                    self.text.moveCursor(QTextCursor.MoveOperation.End)
                    self.text.ensureCursorVisible()

    return PublishLogDock


class PublishWatch:
    """Polls the open planet's publish.log (one stat every 2 s): a message when a publication
    starts and when it ends, with a button to the panel."""

    def __init__(self, iface, on_bake=None):
        from qgis.PyQt.QtCore import QTimer
        self.iface = iface
        #: Offered once a modifier pack is published: its line profiles are stale from then on.
        self.on_bake = on_bake
        self.dock = None
        self._last = None      # (cdir, header, state) seen at the previous tick
        self._sig = None
        self._item = None
        self._btn = None
        self.timer = QTimer()
        self.timer.setInterval(2000)
        self.timer.timeout.connect(self._tick)
        self._prime()
        self.timer.start()

    def _prime(self):
        """What is already in the journal at start-up is not news."""
        cdir = _current_dir()
        if cdir is not None:
            state, header, _ = status(cdir)
            self._last = (cdir, header, state)

    def show(self):
        from qgis.PyQt.QtCore import Qt
        if self.dock is None:
            self.dock = _make_dock_class()(self.iface.mainWindow())
            self.iface.addDockWidget(Qt.DockWidgetArea.BottomDockWidgetArea, self.dock)
        self.dock.show()
        self.dock.raise_()

    def _tick(self):
        cdir = _current_dir()
        if cdir is None:
            self._last = None
            return
        path = os.path.join(cdir, LOG_FILE)
        try:
            st = os.stat(path)
            sig = (path, st.st_size, st.st_mtime_ns)
        except OSError:
            return
        running = running_now(cdir)
        if sig == self._sig and not running and self._last and self._last[2] != RUNNING:
            return
        self._sig = sig
        state, header, body = status(cdir)
        last = self._last
        self._last = (cdir, header, state)
        if last is None or last[0] != cdir or state is None:
            return       # first look at this planet: nothing to announce
        if header == last[1] and state == last[2]:
            return
        planet = os.path.basename(cdir)[:-len("_chunks")]
        what = header.split()[-1] if header else ""
        what = os.path.basename(what)
        if state == RUNNING:
            self._push(f"Publication de {planet} ({what}) en cours.", "info")
        elif state == DONE:
            done = published_line(body).partition(":")[2].strip()
            if what == "terrainmodifier.pack" and self.on_bake is not None:
                self._push(f"Publication terminée : {done or what}. Les profils des lignes "
                           f"sont à recuire.", "success", bake=True)
            else:
                self._push(f"Publication terminée : {done or what}.", "success")
        elif state == NOTHING:
            self._push(f"{planet} ({what}) : déjà publié, rien à faire.", "info")
        elif state == FAILED:
            self._push(f"Échec de la publication de {planet} ({what}).", "critical")
        elif state == STOPPED:
            self._push(f"La publication de {planet} ({what}) s'est arrêtée sans conclure.",
                       "warning")

    def _push(self, text, level, bake=False):
        from qgis.core import Qgis
        from qgis.PyQt.QtCore import QTimer
        from qgis.PyQt.QtWidgets import QPushButton
        levels = {"info": Qgis.MessageLevel.Info, "success": Qgis.MessageLevel.Success,
                  "warning": Qgis.MessageLevel.Warning, "critical": Qgis.MessageLevel.Critical}
        bar = self.iface.messageBar()
        if self._item is not None:      # "en cours" is replaced by how it ended
            try:
                bar.popWidget(self._item)
            except RuntimeError:        # already closed by the user
                pass
            self._item = None
        item = bar.createMessage("DyingStar", text)
        btn = QPushButton("Voir le journal")
        # Deferred: never act from inside a message-bar button's own clicked() (zone_route).
        btn.clicked.connect(lambda _=False: QTimer.singleShot(0, self.show))
        item.layout().addWidget(btn)
        self._btn = (btn,)
        if bake:
            bake_btn = QPushButton("Recuire les profils des lignes")
            bake_btn.clicked.connect(lambda _=False: QTimer.singleShot(0, self.on_bake))
            item.layout().addWidget(bake_btn)
            self._btn = (btn, bake_btn)
        if level == "info":
            self._item = item
        sticky = level in ("critical", "warning", "info") or bake
        bar.pushWidget(item, levels[level], 0 if sticky else 30)

    def unload(self):
        self.timer.stop()
        if self.dock is not None:
            self.iface.removeDockWidget(self.dock)
            self.dock.timer.stop()
            self.dock.deleteLater()
            self.dock = None
