"""The DyingStar menu and toolbar."""
import os

from qgis.core import Qgis
from qgis.PyQt.QtCore import QUrl
from qgis.PyQt.QtGui import QAction, QDesktopServices, QIcon
from qgis.PyQt.QtWidgets import (
    QCheckBox, QComboBox, QDialog, QDialogButtonBox, QDoubleSpinBox, QFormLayout,
    QLabel, QMenu, QMessageBox, QSpinBox, QVBoxLayout,
)

from . import settings
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
        self.actions = []

    # ── QGIS hooks ────────────────────────────────────────────────────────────
    def initGui(self):  # noqa: N802
        settings.apply_env()
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
        self._add(roads, "Aperçu des massifs…", self.mountain_preview,
                  tip="Courbes de niveau et ombrage du relief que Godot donnera aux "
                      "massifs et crêtes tels qu'ils sont dessinés — sans export.")

        pub = self.menu.addMenu("Publication")
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

    def unload(self):
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
        if channel == "prod" and not self._ask(
                "Promouvoir en prod", f"{', '.join(bodies)} → prod : les joueurs le recevront. "
                                      f"Continuer ?"):
            return
        self._job(f"Promotion → {channel}", [Step(JOBS, "promote", channel=channel,
                                                  bodies=bodies)])

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
    CHANNELS = ["dev", "preprod", "prod"]

    def __init__(self, planet, parent=None):
        super().__init__(parent)
        self.setWindowTitle(f"Promouvoir — {planet}")
        self.channel = QComboBox()
        self.channel.addItems(self.CHANNELS)
        self.bodies = []
        form = QFormLayout()
        form.addRow("Vers le canal", self.channel)
        for body, label in ((planet, "Élévation"), (f"{planet}.mod", "Modificateurs"),
                            (f"{planet}.lines", "Profils des lignes")):
            box = QCheckBox(body)
            box.setChecked(body.endswith((".mod", ".lines")))
            form.addRow(label, box)
            self.bodies.append(box)
        note = QLabel("Chaque corps monte d'un cran : unstable → dev → preprod → prod.")
        note.setWordWrap(True)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok
                                   | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout = QVBoxLayout(self)
        layout.addLayout(form)
        layout.addWidget(note)
        layout.addWidget(buttons)

    def choice(self):
        return self.channel.currentText(), [b.text() for b in self.bodies if b.isChecked()]
