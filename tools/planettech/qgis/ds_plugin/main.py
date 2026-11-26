"""The DyingStar menu and toolbar."""
import os

from qgis.core import Qgis
from qgis.PyQt.QtCore import Qt, QUrl
from qgis.PyQt.QtGui import QAction, QDesktopServices, QIcon
from qgis.PyQt.QtWidgets import (
    QCheckBox, QComboBox, QDialog, QDialogButtonBox, QDoubleSpinBox, QFormLayout,
    QHBoxLayout, QLabel, QMenu, QMessageBox, QSpinBox, QVBoxLayout,
)

from . import settings
from .roads_ui import RoadsUi
from .runner import Job, Runner, Step, log_dir

PLUGIN_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKAGE = __name__.split(".")[0]
JOBS = f"{PACKAGE}.ds_plugin.jobs"

#: The five exporters of the modifier pack, in the order "Export everything" runs them.
MODIFIER_EXPORTS = [
    ("export_roads", "Routes"),
    ("export_biomes", "Régions"),
    ("export_mountains", "Massifs"),
    ("export_volcanoes", "Volcans"),
    ("export_rocky_terrain", "Terrain rocheux"),
]


class DyingStarPlugin:
    def __init__(self, iface):
        self.iface = iface
        self.runner = Runner(iface, PLUGIN_DIR, PACKAGE)
        self.menu = None
        self.toolbar = None
        self.roads = None
        self.publish_watch = None
        self.actions = []

    # ── QGIS hooks ────────────────────────────────────────────────────────────
    def initGui(self):  # noqa: N802
        settings.apply_env()
        self._enable_crash_trace()
        win = self.iface.mainWindow()
        self.menu = QMenu("DyingStar", win)
        self.menu.setObjectName("DyingStarMenu")
        self.toolbar = self.iface.addToolBar("DyingStar")
        self.toolbar.setObjectName("DyingStarToolbar")

        icon = QIcon(os.path.join(PLUGIN_DIR, "icon.svg"))
        self._add(self.menu, "Projet planète…", self.setup_project, icon=icon, toolbar=True,
                  tip="Crée ou rouvre une planète : schéma PostGIS, couches, projet QGIS.")
        self._add(self.menu, "Mettre à jour les couches…", self.update_layers,
                  tip="Ré-applique les définitions de couches (champs, styles, groupes) au "
                      "projet ouvert, sans redemander nom et rayon.")
        self.menu.addSeparator()

        exp = self.menu.addMenu("Exporter")
        self._add(exp, "Élévation (heights.pack)…", self.export_elevation,
                  tip="Les courbes de niveau → la pyramide d'élévation. Long : des minutes à "
                      "des dizaines d'heures selon la planète.")
        exp.addSeparator()
        for module, label in MODIFIER_EXPORTS:
            self._add(exp, label, lambda _=False, m=module, l=label: self._export(m, l))
        self._add(exp, "Tout le pack de modificateurs", self.export_all_modifiers,
                  tip="Routes, régions, massifs, volcans, terrain rocheux, puis un seul lien.")
        exp.addSeparator()
        self._add(exp, "POI et régions nommées", lambda: self._export("export_poi", "POI"))
        self._add(exp, "Grottes", lambda: self._export("export_cave_sites", "Grottes"))

        roads = self.menu.addMenu("Routes")
        self.roads = RoadsUi(self)
        self._add(roads, "Terrain de la zone…", self.roads.zone_terrain,
                  tip="Altitude, courbes et pente de la zone affichée, classée selon la pente "
                      "max de la route ; source rapide (QGIS) ou exacte (Godot).")
        self._add(roads, "Tracer une route…", self.roads.draw_route,
                  tip="Le tracé calculé entre tes clics, qui tient la pente max sur le terrain "
                      "de la zone : lacets, détours, ouvrages seulement où il le faut.")
        self._add(roads, "Profil en long", lambda: self.roads.toggle_profile(True),
                  tip="Le profil que le jeu donnera à la route sélectionnée, sur le terrain "
                      "de la zone : tranchées, tunnels, viaducs.")
        self._add(roads, "Aperçu des massifs…", self.mountain_preview,
                  tip="Courbes de niveau et ombrage du relief que Godot donnera aux "
                      "massifs et crêtes tels qu'ils sont dessinés — sans export.")

        pub = self.menu.addMenu("Publication")
        from .publish_log import PublishWatch
        self.publish_watch = PublishWatch(self.iface, on_bake=self.bake_lines)
        self._add(pub, "Journal de publication", self.publish_watch.show,
                  tip="Le journal de la publication en arrière-plan (publish.log de la "
                      "planète), suivi en direct : elle continue après la fin de l'export.")
        self._add(pub, "Recuire les profils des lignes", self.bake_lines,
                  tip="Après chaque publication du pack de modificateurs : profils des voies "
                      "ferrées et routes à pente, ponts sur crevasse (Godot headless, ~10 min), "
                      "puis publication. Sans ça, le jeu les recalcule en jouant : routes "
                      "coupées à un bord de chunk, trous le long des tranchées.")
        pub.addSeparator()
        self._add(pub, "Récupérer les parts du serveur", lambda: self._job(
            "Récupérer les parts", [Step(JOBS, "pull")]))
        self._add(pub, "Relier le pack de modificateurs", lambda: self._job(
            "Relier le pack", [Step(JOBS, "link")]))
        self._add(pub, "Promouvoir…", self.promote)
        self._add(pub, "Vérifier la cible de publication", lambda: self._job(
            "Vérifier la cible", [Step(JOBS, "check")]))

        tools = self.menu.addMenu("Outils")
        self._add(tools, "Migrer les couches volcaniques…", self.migrate_volcanic)
        self._add(tools, "Sonder l'élagage du pack", lambda: self._job(
            "Sonder l'élagage", [Step("probe_pack_sparsity", "run")]))
        self._add(tools, "Écrire rocks.json", lambda: self._job(
            "rocks.json", [Step("export_rocks", "write")]))

        self.menu.addSeparator()
        self._add(self.menu, "Journal", self.open_log)
        self._add(self.menu, "Dossier des journaux", lambda: QDesktopServices.openUrl(
            QUrl.fromLocalFile(log_dir())))
        self._add(self.menu, "Paramètres…", self.open_settings)

        bar = win.menuBar()
        help_menu = next((a for a in bar.actions() if a.menu() is not None
                          and a.menu().objectName() == "mHelpMenu"), None)
        if help_menu is not None:
            bar.insertMenu(help_menu, self.menu)
        else:
            bar.addMenu(self.menu)

    def _enable_crash_trace(self):
        """On a crash (SIGSEGV, SIGABRT…) Python writes its own stack to
        <profile>/DyingStar/logs/python_crash.log: the C stack of a core dump stops at the
        interpreter and does not say which line of the plugin was running."""
        import faulthandler
        try:
            self._crash_file = open(os.path.join(log_dir(), "python_crash.log"), "a",
                                    encoding="utf-8")
            faulthandler.enable(file=self._crash_file, all_threads=False)
        except (OSError, RuntimeError):
            self._crash_file = None

    def unload(self):
        if getattr(self, "_crash_file", None) is not None:
            import faulthandler
            faulthandler.disable()
            self._crash_file.close()
            self._crash_file = None
        if self.roads is not None:
            self.roads.unload()
            self.roads = None
        if self.publish_watch is not None:
            self.publish_watch.unload()
            self.publish_watch = None
        for action in self.actions:
            self.iface.removeToolBarIcon(action)
        if self.toolbar is not None:
            self.toolbar.deleteLater()
        if self.menu is not None:
            self.menu.menuAction().setVisible(False)
            self.menu.deleteLater()
        self.actions = []

    # ── helpers ───────────────────────────────────────────────────────────────
    def _add(self, menu, text, slot, icon=None, toolbar=False, tip=None):
        action = QAction(icon, text, self.iface.mainWindow()) if icon else \
            QAction(text, self.iface.mainWindow())
        action.triggered.connect(lambda _checked=False: slot())
        if tip:
            action.setToolTip(tip)
            action.setStatusTip(tip)
        menu.addAction(action)
        if toolbar:
            self.toolbar.addAction(action)
        self.actions.append(action)
        return action

    def _job(self, title, steps, busy_cursor=True):
        return self.runner.run(Job(title, steps, busy_cursor=busy_cursor))

    def _export(self, module, label):
        self._job(f"Export {label}", [Step(module)])

    def _ask(self, title, text):
        answer = QMessageBox.question(self.iface.mainWindow(), title, text,
                                      QMessageBox.StandardButton.Yes
                                      | QMessageBox.StandardButton.No)
        return answer == QMessageBox.StandardButton.Yes

    # ── actions ───────────────────────────────────────────────────────────────
    def setup_project(self):
        self._job("Projet planète", [Step("setup_planet_project", "run", interactive=True,
                                          decorations=settings.value("decorations", False))],
                  busy_cursor=False)

    def update_layers(self):
        self._job("Mise à jour des couches", [Step("setup_planet_project", "run",
                                                   interactive=True, update=True)],
                  busy_cursor=False)

    def export_elevation(self):
        if self._ask("Export de l'élévation",
                     "L'export d'élévation reconstruit toute la pyramide heights.pack depuis les "
                     "courbes de niveau. Il dure de quelques minutes à des dizaines d'heures "
                     "(tarsis_3 : ~35 h) et tourne en tâche de fond, annulable.\n\n"
                     "Le plan (tuiles, résolution, durée estimée) s'affiche dans le journal "
                     "dès le lancement. Lancer ?"):
            self._export("export_elevation", "élévation")

    def export_all_modifiers(self):
        steps = [Step(module, no_link=True) for module, _label in MODIFIER_EXPORTS]
        steps.append(Step(JOBS, "link"))
        self._job("Export du pack de modificateurs", steps)

    def migrate_volcanic(self):
        if self._ask("Migrer les couches volcaniques",
                     "Crée les tables volcano / lava_flow / fumarole_* et y copie les anciennes "
                     "(active_volcano, lava_dome, lava_river, fumarole). Rien n'est supprimé. "
                     "Une seule fois par planète. Continuer ?"):
            self._job("Migration volcanique", [Step("migrate_volcanic_layers", "run")])

    def mountain_preview(self):
        dlg = MountainPreviewDialog(self.iface.mainWindow())
        if dlg.exec() == QDialog.DialogCode.Accepted:
            self._job("Aperçu des massifs", [Step("preview_mountain_contours", **dlg.options())])

    def promote(self):
        try:
            import ds_project
            planet = ds_project.planet().name
        except Exception as exc:  # noqa: BLE001
            self.iface.messageBar().pushMessage("DyingStar", str(exc), Qgis.MessageLevel.Critical)
            return
        dlg = PromoteDialog(planet, self.iface.mainWindow())
        if dlg.exec() != QDialog.DialogCode.Accepted:
            return
        channel, bodies = dlg.choice()
        if not bodies:
            return
        if dlg.risky() and not self._ask(
                "Profils des lignes", "Les modificateurs montent sans profils des lignes cuits "
                                      "pour eux : le jeu les recalculera en jouant (routes "
                                      "coupées, trous). Promouvoir quand même ?"):
            return
        if channel == "prod" and not self._ask(
                "Promouvoir en prod", f"{', '.join(bodies)} → prod : les joueurs le recevront. "
                                      f"Continuer ?"):
            return
        self._job(f"Promotion → {channel}", [Step(JOBS, "promote", channel=channel,
                                                  bodies=bodies)])

    def bake_lines(self):
        self._job("Profils des lignes", [Step("bake_lines")], busy_cursor=False)

    def open_log(self):
        if hasattr(self.iface, "openMessageLog"):
            self.iface.openMessageLog("DyingStar")

    def open_settings(self):
        settings.SettingsDialog(self.iface.mainWindow()).exec()


class MountainPreviewDialog(QDialog):
    """The options of preview_mountain_contours.py, remembered between runs."""

    _KEY = "mountain_preview/"

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Aperçu des massifs")
        form = QFormLayout()
        self.interval = self._dspin(settings.value(self._KEY + "interval_m", "50"), 1, 1000, 5,
                                    " m")
        self.index_every = QSpinBox()
        self.index_every.setRange(1, 20)
        self.index_every.setValue(int(settings.value(self._KEY + "index_every", "5")))
        self.spacing = self._dspin(settings.value(self._KEY + "spacing_m", "50"), 5, 5000, 5, " m")
        self.only_canvas = self._check(self._KEY + "only_canvas", True)
        self.add_ground = self._check(self._KEY + "add_ground", False)
        self.add_relief = self._check(self._KEY + "add_relief", True)
        self.only_selected = self._check(self._KEY + "only_selected", False)
        form.addRow("Équidistance des courbes", self.interval)
        form.addRow("Courbe maîtresse toutes les", self.index_every)
        form.addRow("Pas de la grille", self.spacing)
        form.addRow("Emprise de la carte seulement", self.only_canvas)
        form.addRow("Altitude absolue (+ heightmap.tif)", self.add_ground)
        form.addRow("Ombrage du relief", self.add_relief)
        form.addRow("Entités sélectionnées seulement", self.only_selected)
        note = QLabel("Volcans et terrain rocheux non compris. Pas plus fin = plus de détail, "
                      "temps ∝ 1/pas².")
        note.setWordWrap(True)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok
                                   | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self._save)
        buttons.rejected.connect(self.reject)
        layout = QVBoxLayout(self)
        layout.addLayout(form)
        layout.addWidget(note)
        layout.addWidget(buttons)

    @staticmethod
    def _dspin(val, lo, hi, step, suffix):
        w = QDoubleSpinBox()
        w.setRange(lo, hi)
        w.setSingleStep(step)
        w.setDecimals(0)
        w.setSuffix(suffix)
        w.setValue(float(val))
        return w

    @staticmethod
    def _check(key, default):
        w = QCheckBox()
        w.setChecked(settings.value(key, default))
        return w

    def options(self):
        return {
            "interval_m": float(self.interval.value()),
            "index_every": int(self.index_every.value()),
            "spacing_m": float(self.spacing.value()),
            "only_canvas": self.only_canvas.isChecked(),
            "add_ground": self.add_ground.isChecked(),
            "add_relief": self.add_relief.isChecked(),
            "only_selected": self.only_selected.isChecked(),
        }

    def _save(self):
        for key, v in self.options().items():
            settings.set_value(self._KEY + key, v if isinstance(v, bool) else str(v))
        self.accept()


class PromoteDialog(QDialog):
    """Channel and bodies, with what each side serves: a body already up to date is left out,
    and modifiers going up without the line profiles baked for them are flagged."""
    CHANNELS = ["dev", "preprod", "prod"]

    def __init__(self, planet, parent=None):
        super().__init__(parent)
        self.planet = planet
        self.setWindowTitle(f"Promouvoir — {planet}")
        self.channel = QComboBox()
        self.channel.addItems(self.CHANNELS)
        self.bodies = []
        self.states = []
        form = QFormLayout()
        form.addRow("Vers le canal", self.channel)
        for body, label in ((planet, "Élévation"), (f"{planet}.mod", "Modificateurs"),
                            (f"{planet}.lines", "Profils des lignes")):
            box = QCheckBox(body)
            state = QLabel()
            state.setTextFormat(Qt.TextFormat.RichText)
            row = QHBoxLayout()
            row.addWidget(box)
            row.addWidget(state, 1)
            form.addRow(label, row)
            self.bodies.append(box)
            self.states.append(state)
            box.toggled.connect(lambda _on: self._check_lines())
        self.warning = QLabel()
        self.warning.setWordWrap(True)
        self.warning.setTextFormat(Qt.TextFormat.RichText)
        note = QLabel("Chaque corps monte d'un cran : unstable → dev → preprod → prod.")
        note.setWordWrap(True)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok
                                   | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout = QVBoxLayout(self)
        layout.addLayout(form)
        layout.addWidget(self.warning)
        layout.addWidget(note)
        layout.addWidget(buttons)
        self.served = {}
        self.src = "unstable"
        self.lines_ok = None
        self.channel.currentTextChanged.connect(self._refresh)
        self._refresh()

    def _refresh(self, *_):
        """Read both channels (HTTP, as the game) and fill each body's line."""
        import channels
        import link_modifiers
        to = self.channel.currentText()
        src = self.src = channels.previous(to)
        try:
            self.served = {src: channels.read(src), to: channels.read(to)}
        except Exception as exc:  # noqa: BLE001 — the promotion itself does not need it
            self.served = {}
            for box, state in zip(self.bodies, self.states):
                box.setChecked(box.text().endswith((".mod", ".lines")))
                state.setText("<i>versions illisibles</i>")
            self.lines_ok = None
            self.warning.setText(f"Canaux illisibles en HTTP ({exc}) : promotion à l'aveugle.")
            return
        for box, state in zip(self.bodies, self.states):
            a = self.served[src].get(box.text(), "")
            b = self.served[to].get(box.text(), "")
            if not a:
                box.setChecked(False)
                box.setEnabled(False)
                state.setText(f"<i>absent de {src}</i>")
            elif a == b:
                box.setEnabled(True)
                box.setChecked(False)
                state.setText(f"<span style='color:#3a9d23'>à jour</span> ({a[:8]})")
            else:
                box.setEnabled(True)
                box.setChecked(box.text().endswith((".mod", ".lines")))
                state.setText(f"{src} <b>{a[:8]}</b> → {to} {b[:8] or '—'}")
        chunks = link_modifiers.chunks_dir_for(self.planet, link_modifiers.resolve_export_dir())
        self.lines_ok = channels.lines_verdict(chunks, self.planet, self.served[src])
        self._check_lines()

    def _check_lines(self):
        """The game reads the profiles only if they were baked for the modifiers it gets."""
        if not self.served:
            return
        src = self.src
        mod_box = self.bodies[1]
        msgs = []
        if mod_box.isChecked() and self.lines_ok is False:
            msgs.append(f"<span style='color:#d7301f'><b>Les profils des lignes de {src} n'ont "
                        f"pas été cuits pour ses modificateurs</b> : le jeu les recalculerait en "
                        f"jouant (routes coupées aux bords de chunk, trous). Recuis-les d'abord "
                        f"(Publication ▸ Recuire les profils des lignes).</span>")
        elif self._lines_left_behind():
            msgs.append("<span style='color:#d7301f'>Les modificateurs montent sans les profils "
                        "des lignes cuits pour eux.</span>")
        elif mod_box.isChecked() and self.lines_ok is None:
            msgs.append("<i>Profils des lignes : cuits ailleurs qu'ici, leur accord avec les "
                        "modificateurs n'est pas vérifiable.</i>")
        elif self.lines_ok:
            msgs.append(f"<span style='color:#3a9d23'>Profils des lignes cuits pour les "
                        f"modificateurs de {src}.</span>")
        self.warning.setText("<br>".join(msgs))

    def _lines_left_behind(self):
        """Modifiers checked, the line profiles differing between the channels but unchecked."""
        mod_box, lines_box = self.bodies[1], self.bodies[2]
        if not self.served or not mod_box.isChecked() or lines_box.isChecked():
            return False
        body, to = lines_box.text(), self.channel.currentText()
        return bool(self.served[self.src].get(body)) \
            and self.served[self.src].get(body) != self.served[to].get(body)

    def risky(self):
        """Modifiers going up while the profiles on the source channel are not theirs."""
        return self.bodies[1].isChecked() and (self.lines_ok is False
                                               or self._lines_left_behind())

    def choice(self):
        return self.channel.currentText(), [b.text() for b in self.bodies if b.isChecked()]
