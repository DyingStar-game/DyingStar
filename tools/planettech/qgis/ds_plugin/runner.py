"""Runs the pipeline scripts from the plugin: fresh code, main thread for the layers,
a background QgsTask for the rest, every print() into the QGIS log and a file.

The contract of a script module (export_roads.py, …):
    prepare(**kwargs) -> work | None     main thread: reads the project and the layers
    work() -> finish | None              any thread: computes and writes files
    finish()                             main thread: adds layers to the project…
A script that only touches layers does everything in prepare() and returns None.
"""
import datetime
import importlib
import os
import sys
import threading
import time
import traceback

from qgis.core import Qgis, QgsApplication, QgsMessageLog, QgsTask
from qgis.PyQt.QtCore import QObject, pyqtSignal
from qgis.PyQt.QtWidgets import QApplication
from qgis.PyQt.QtGui import QCursor
from qgis.PyQt.QtCore import Qt

LOG_TAG = "DyingStar"


class Cancelled(Exception):
    """Raised inside a script by its progress hook once the task is cancelled."""


# ── print() routing ──────────────────────────────────────────────────────────────
class _Sink:
    """One job's log: QgsMessageLog (thread-safe) line by line, plus a file."""

    def __init__(self, path):
        self.path = path
        self._file = open(path, "a", encoding="utf-8", buffering=1)
        self._buf = ""
        self._lock = threading.Lock()

    def write(self, text):
        with self._lock:
            self._file.write(text)
            self._buf += text
            while "\n" in self._buf:
                line, self._buf = self._buf.split("\n", 1)
                QgsMessageLog.logMessage(line, LOG_TAG, Qgis.MessageLevel.Info, False)

    def close(self):
        with self._lock:
            if self._buf:
                QgsMessageLog.logMessage(self._buf, LOG_TAG, Qgis.MessageLevel.Info, False)
                self._buf = ""
            self._file.close()


class _Router:
    """Replaces sys.stdout / sys.stderr while a job runs. A thread the job captured writes to
    its sink; the main thread ALSO to the stream it replaced (the Python console when it is
    open); a worker thread never touches that stream — the console is a widget, not
    thread-safe — only the terminal QGIS was started from."""

    def __init__(self, wrapped, terminal):
        self.wrapped = wrapped
        self.terminal = terminal
        self.sinks = {}

    def write(self, text):
        sink = self.sinks.get(threading.get_ident())
        if sink is not None:
            sink.write(text)
        if threading.current_thread() is threading.main_thread():
            self.wrapped.write(text)
        elif self.terminal is not None:
            try:
                self.terminal.write(text)
            except Exception:  # noqa: BLE001 — no terminal (Windows GUI start)
                pass
        return len(text)

    def flush(self):
        if threading.current_thread() is threading.main_thread():
            try:
                self.wrapped.flush()
            except Exception:  # noqa: BLE001
                pass

    def __getattr__(self, name):
        return getattr(self.wrapped, name)


class _Capture:
    """`with _Capture(sink):` routes this thread's print() to [sink]."""

    _lock = threading.Lock()
    _users = 0
    _saved = None

    def __init__(self, sink):
        self.sink = sink

    def __enter__(self):
        cls = _Capture
        with cls._lock:
            if cls._users == 0:
                cls._saved = (sys.stdout, sys.stderr)
                sys.stdout = _Router(sys.stdout, sys.__stdout__)
                sys.stderr = _Router(sys.stderr, sys.__stderr__)
            cls._users += 1
            sys.stdout.sinks[threading.get_ident()] = self.sink
            sys.stderr.sinks[threading.get_ident()] = self.sink
        return self

    def __exit__(self, *exc):
        cls = _Capture
        with cls._lock:
            for stream in (sys.stdout, sys.stderr):
                if isinstance(stream, _Router):
                    stream.sinks.pop(threading.get_ident(), None)
            cls._users -= 1
            if cls._users == 0 and cls._saved is not None:
                # Restore only our own routers: something that replaced them meanwhile
                # (the console opening) keeps its stream.
                if isinstance(sys.stdout, _Router):
                    sys.stdout = cls._saved[0]
                if isinstance(sys.stderr, _Router):
                    sys.stderr = cls._saved[1]
                cls._saved = None
        return False


def log_dir():
    d = os.path.join(QgsApplication.qgisSettingsDirPath(), "DyingStar", "logs")
    os.makedirs(d, exist_ok=True)
    return d


def _prune_logs(keep=50):
    d = log_dir()
    files = sorted((os.path.join(d, f) for f in os.listdir(d) if f.endswith(".log")),
                   key=os.path.getmtime)
    for path in files[:-keep]:
        try:
            os.remove(path)
        except OSError:
            pass


# ── Fresh code at every run ────────────────────────────────────────────────────
def purge_modules(plugin_dir, package):
    """Forget every pipeline module so the next import reads the files again.

    The QGIS interpreter lives as long as QGIS: without this, an edited exporter would keep
    running yesterday's code (what the old `exec(open(...))` header did by hand). The
    plugin's own package stays: it is the code doing the purge.
    """
    roots = [os.path.realpath(plugin_dir) + os.sep, os.path.abspath(plugin_dir) + os.sep]
    import link_modifiers
    repo = link_modifiers.repo_root()
    if repo:
        roots.append(os.path.join(os.path.realpath(repo), "tools") + os.sep)
    roots = tuple(roots)
    for name, mod in list(sys.modules.items()):
        if name == package or name.startswith(package + "."):
            continue
        path = getattr(mod, "__file__", None)
        if path:
            if os.path.abspath(path).startswith(roots) or os.path.realpath(path).startswith(roots):
                del sys.modules[name]
        elif name in ("export", "layers", "tools") or name.startswith(("export.", "layers.",
                                                                         "tools.")):
            del sys.modules[name]


# ── Jobs ───────────────────────────────────────────────────────────────────────
class Step:
    """One script of a job: [module].[func](**kwargs), `prepare` by default."""

    def __init__(self, module, func="prepare", **kwargs):
        self.module = module
        self.func = func
        self.kwargs = kwargs


class _Task(QgsTask):
    def __init__(self, job, works, sink):
        super().__init__(job.title, QgsTask.Flag.CanCancel)
        self.job = job
        self.works = works
        self.sink = sink
        self.finishes = []
        self.error = None

    def report(self, fraction):
        """The scripts' progress hook: progress, and the cancellation point."""
        self.setProgress(max(0.0, min(100.0, 100.0 * fraction)))
        if self.isCanceled():
            raise Cancelled()

    def run(self):
        with _Capture(self.sink):
            try:
                for i, (mod, work) in enumerate(self.works):
                    if self.isCanceled():
                        raise Cancelled()
                    if hasattr(mod, "PROGRESS"):
                        n = len(self.works)
                        mod.PROGRESS = (lambda f, i=i, n=n: self.report((i + f) / n))
                    finish = work()
                    if callable(finish):
                        self.finishes.append(finish)
                    self.setProgress(100.0 * (i + 1) / len(self.works))
                return True
            except Cancelled:
                print("  ✗ Cancelled.")
                self.error = "annulé"
                return False
            except Exception as exc:  # noqa: BLE001 — reported in the log and the message bar
                traceback.print_exc()
                self.error = f"{type(exc).__name__}: {exc}"
                return False
            finally:
                for mod, _work in self.works:
                    if hasattr(mod, "PROGRESS"):
                        mod.PROGRESS = None


class Job:
    def __init__(self, title, steps, busy_cursor=True):
        self.title = title
        #: [Step]: each prepare() on the main thread in order, then their works in order.
        self.steps = steps
        #: False for a job that opens dialogs during prepare().
        self.busy_cursor = busy_cursor


class _Notifier(QObject):
    done = pyqtSignal(str, bool)


class Runner:
    """At most one job at a time: the exporters share parts/ and the string table."""

    def __init__(self, iface, plugin_dir, package):
        self.iface = iface
        self.plugin_dir = plugin_dir
        self.package = package
        self.task = None
        self.notifier = _Notifier()

    @property
    def busy(self):
        return self.task is not None

    def _bar(self, text, level=Qgis.MessageLevel.Info, duration=6):
        if self.iface is not None:
            self.iface.messageBar().pushMessage("DyingStar", text, level, duration)

    def run(self, job):
        if self.busy:
            self._bar(f"« {self.task.description()} » est en cours : attends la fin ou annule-la "
                      f"(barre des tâches en bas).", Qgis.MessageLevel.Warning)
            return False
        stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        _prune_logs()
        slug = "".join(c if c.isalnum() else "_" for c in job.title.lower())[:40]
        sink = _Sink(os.path.join(log_dir(), f"{stamp}_{slug}.log"))
        purge_modules(self.plugin_dir, self.package)
        works = []
        if job.busy_cursor:
            QApplication.setOverrideCursor(QCursor(Qt.CursorShape.WaitCursor))
        t0 = time.perf_counter()
        try:
            with _Capture(sink):
                print(f"── {job.title} — {datetime.datetime.now():%Y-%m-%d %H:%M:%S}")
                for step in job.steps:
                    mod = importlib.import_module(step.module)
                    work = getattr(mod, step.func)(**step.kwargs)
                    if callable(work):
                        works.append((mod, work))
        except Exception as exc:  # noqa: BLE001
            import ds_project
            with _Capture(sink):
                if isinstance(exc, ds_project.NotAPlanetProject):
                    print(f"  ✗ {exc}")
                else:
                    traceback.print_exc()
            sink.close()
            if job.busy_cursor:
                QApplication.restoreOverrideCursor()
            self._error(job, exc, sink.path)
            return False
        if job.busy_cursor:
            QApplication.restoreOverrideCursor()
        if not works:
            sink.close()
            self._bar(f"{job.title} : terminé ({time.perf_counter() - t0:.1f} s). Journal : "
                      f"onglet « {LOG_TAG} » du panneau Journal.", Qgis.MessageLevel.Success)
            self.notifier.done.emit(job.title, True)
            return True
        task = _Task(job, works, sink)
        task.taskCompleted.connect(lambda: self._finished(task, True, t0))
        task.taskTerminated.connect(lambda: self._finished(task, False, t0))
        self.task = task
        QgsApplication.taskManager().addTask(task)
        self._bar(f"{job.title} : lancé en tâche de fond (progression en bas de la fenêtre).",
                  duration=4)
        return True

    def _finished(self, task, ok, t0):
        self.task = None
        if ok:
            try:
                with _Capture(task.sink):
                    for finish in task.finishes:
                        finish()
            except Exception as exc:  # noqa: BLE001
                with _Capture(task.sink):
                    traceback.print_exc()
                task.sink.close()
                self._error(task.job, exc, task.sink.path)
                return
        task.sink.close()
        elapsed = time.perf_counter() - t0
        if ok:
            self._bar(f"{task.job.title} : terminé en {_duration(elapsed)}.",
                      Qgis.MessageLevel.Success)
        else:
            self._bar(f"{task.job.title} : échec ({task.error or 'interrompu'}). "
                      f"Journal : {task.sink.path}", Qgis.MessageLevel.Critical, 0)
        self.notifier.done.emit(task.job.title, ok)

    def _error(self, job, exc, log_path):
        import ds_project
        if isinstance(exc, ds_project.NotAPlanetProject):
            text = str(exc)
        else:
            text = f"{type(exc).__name__}: {exc}. Journal : {log_path}"
        self._bar(f"{job.title} : {text}", Qgis.MessageLevel.Critical, 0)
        self.notifier.done.emit(job.title, False)


def _duration(seconds):
    h, rem = divmod(int(seconds), 3600)
    m, s = divmod(rem, 60)
    return f"{h}h{m:02d}m{s:02d}s" if h else (f"{m}m{s:02d}s" if m else f"{seconds:.1f} s")
