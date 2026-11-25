"""The plugin's settings, handed to the scripts as environment variables.

The scripts already resolve every path through an environment variable first
(link_modifiers.resolve_path, publish_remote.load_config, …), then export_config.ini, then
a default. The plugin keeps its settings in QgsSettings and sets those variables, so the
scripts — and the publication they start in the background, a separate process — see the
same values. An empty setting leaves the variable alone (export_config.ini or the default
then decide).
"""
import os

from qgis.core import QgsSettings
from qgis.gui import QgsFileWidget
from qgis.PyQt.QtWidgets import (
    QCheckBox, QDialog, QDialogButtonBox, QFormLayout, QGroupBox, QLabel, QLineEdit, QVBoxLayout,
)

_PREFIX = "DyingStar/"


class Setting:
    def __init__(self, key, env, label, tooltip, kind="text"):
        self.key = key
        self.env = env
        self.label = label
        self.tooltip = tooltip
        #: "dir", "file", "text" or "bool".
        self.kind = kind


PATHS = [
    Setting("repo_dir", "DS_REPO_DIR", "Dépôt DyingStar (plugin installé par zip)",
            "Seulement pour un plugin installé depuis un zip : le clone du dépôt du jeu. Un plugin "
            "chargé depuis un clone (lien symbolique) utilise toujours ce clone-là, pour que les "
            "outils Godot lancés soient de la même version que lui.",
            "dir"),
    Setting("export_dir", "DS_EXPORT_DIR", "Dossier d'export",
            "Où les exports écrivent <planète>_chunks/… Vide : <dépôt>/assets/qgis/export.", "dir"),
    Setting("projects_dir", "DS_QGIS_PROJECTS_DIR", "Dossier des projets QGIS",
            "Où « Projet planète » enregistre un NOUVEAU projet (<dossier>/<planète>/<planète>.qgz). "
            "Un projet déjà enregistré reste à sa place. Vide : <dépôt>/assets/qgis.", "dir"),
    Setting("existing_features", "DS_EXISTING_FEATURES", "GeoJSON de référence",
            "Optionnel : un GeoJSON chargé à la racine du projet par « Projet planète ».", "file"),
    Setting("cave_export_dir", "DS_CAVE_EXPORT_DIR", "Dossier d'export des grottes",
            "Privé, hors du dépôt. Vide : ~/dyingstar-private/caves.", "dir"),
    Setting("startup_items", "DS_STARTUP_ITEMS", "startup_items.json (Horizon)",
            "Les villages dont les routes sont découpées à l'export. "
            "Vide : ../horizonserver/ds_genericprops/startup_items.json à côté du dépôt.", "file"),
    Setting("godot_bin", "GODOT_BIN", "Binaire Godot",
            "Le Godot du projet (double précision, mono), pour les outils lancés sans fenêtre "
            "(terrain de la zone, profils).", "file"),
]

PUBLISH = [
    Setting("publish_ssh", "DS_PUBLISH_SSH", "SSH",
            "utilisateur@serveur du service de tuiles. Vide : pas de publication automatique "
            "(sauf export_config.ini [publish])."),
    Setting("publish_port", "DS_PUBLISH_PORT", "Port", "Port SSH (22)."),
    Setting("publish_dist", "DS_PUBLISH_DIST", "dist", "Racine servie par nginx (/var/www/dist)."),
    Setting("publish_workdir", "DS_PUBLISH_WORKDIR", "Dossier de travail",
            "Sur le serveur, où les packs sont reçus (ds-publish)."),
    Setting("publish_python", "DS_PUBLISH_PYTHON", "python du serveur", "python3"),
    Setting("publish_channel", "DS_PUBLISH_CHANNEL", "Canal", "Canal où un export arrive (unstable)."),
    Setting("publish_http", "DS_PUBLISH_HTTP", "URL HTTP",
            "Pour vérifier un échantillon après publication. Vide : client.ini [stream] tiles_url."),
]

OPTIONS = [
    Setting("decorations", None, "Grille 10° et barre d'échelle",
            "« Projet planète » règle aussi la grille et la barre d'échelle de QGIS "
            "(réglages de l'utilisateur, pour tous ses projets).", "bool"),
]

ALL = PATHS + PUBLISH + OPTIONS

#: Variables this session set, so clearing a setting also clears its variable.
_set_by_plugin = set()


def value(key, default=""):
    v = QgsSettings().value(_PREFIX + key, default)
    if isinstance(default, bool):
        return v in (True, "true", "True", "1", 1)
    return "" if v is None else str(v)


def set_value(key, v):
    QgsSettings().setValue(_PREFIX + key, v)


def apply_env():
    """Hand every non-empty setting to the scripts as its environment variable."""
    for s in ALL:
        if not s.env:
            continue
        v = value(s.key).strip()
        if v:
            os.environ[s.env] = os.path.expanduser(v)
            _set_by_plugin.add(s.env)
        elif s.env in _set_by_plugin:
            os.environ.pop(s.env, None)
            _set_by_plugin.discard(s.env)


def detected_repo():
    """The checkout the scripts will use, or None — shown in the dialog."""
    import link_modifiers
    return link_modifiers.repo_root()


class SettingsDialog(QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("DyingStar — Paramètres")
        self.setMinimumWidth(640)
        self._widgets = {}
        layout = QVBoxLayout(self)
        for title, group in (("Chemins", PATHS), ("Publication sur le service de tuiles", PUBLISH),
                             ("Options", OPTIONS)):
            box = QGroupBox(title)
            form = QFormLayout(box)
            for s in group:
                w = self._widget(s)
                label = QLabel(s.label)
                label.setToolTip(s.tooltip)
                w.setToolTip(s.tooltip)
                form.addRow(label, w)
                self._widgets[s.key] = w
            layout.addWidget(box)
        repo = detected_repo()
        hint = QLabel(f"Dépôt utilisé (outils Godot, publication) : {repo}" if repo else
                      "Dépôt introuvable : renseigne « Dépôt DyingStar ».")
        hint.setWordWrap(True)
        layout.addWidget(hint)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok
                                   | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self._save)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _widget(self, s):
        if s.kind == "bool":
            w = QCheckBox()
            w.setChecked(value(s.key, False))
            return w
        if s.kind in ("dir", "file"):
            w = QgsFileWidget()
            w.setStorageMode(QgsFileWidget.StorageMode.GetDirectory if s.kind == "dir"
                             else QgsFileWidget.StorageMode.GetFile)
            w.setFilePath(value(s.key))
            return w
        w = QLineEdit(value(s.key))
        return w

    def _save(self):
        for s in ALL:
            w = self._widgets[s.key]
            if s.kind == "bool":
                set_value(s.key, w.isChecked())
            elif s.kind in ("dir", "file"):
                set_value(s.key, w.filePath().strip())
            else:
                set_value(s.key, w.text().strip())
        apply_env()
        self.accept()
