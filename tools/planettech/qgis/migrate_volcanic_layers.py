"""
One-shot migration of a planet's volcanic tables to layers/volcanoes.py.
=========================================================================

The volcanoes, lava flows and fumaroles left the biome layers
(layers/biomes/volcanic_geothermal.py) for layers/volcanoes.py, where Godot
builds them procedurally (export_volcanoes.py).  This script, run once per
planet from the QGIS Python Console with the planet project open:

  1. creates the new tables (volcano, lava_flow, fumarole_vent) if missing;
  2. adds the new columns to fumarole_field (it keeps its table);
  3. COPIES the rows of the old tables into the new ones — only into a new
     table that is still empty, so running it twice copies nothing twice:
         active_volcano  → volcano    (shape cone → stratovolcano; base_diameter,
                                       height, crater_diameter → *_m)
         lava_dome       → volcano    (type lava_dome, diameter = 2 × radius)
         lava_river      → lava_flow  (state active; width_start/end → *_m)
         fumarole        → fumarole_vent
  4. drops nothing: check the new layers, then drop the old tables yourself.

Re-run setup_planet_project.py afterwards so the project gets the new layers
(and loses the old biome ones).

Run from the QGIS Python Console:
    exec(open('/datas/developpement/sources/DyingStar-game/DyingStar/tools/planettech/qgis/migrate_volcanic_layers.py').read())
"""

import os
import sys

from qgis.core import QgsProject, QgsExpressionContextUtils

_THIS_DIR = os.path.dirname(os.path.abspath(__file__)) \
    if "__file__" in globals() else \
    "/datas/developpement/sources/DyingStar-game/DyingStar/tools/planettech/qgis"
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)
for _name in list(sys.modules):
    _mod = sys.modules.get(_name)
    _file = getattr(_mod, "__file__", None) or ""
    if _file and os.path.abspath(_file).startswith(_THIS_DIR + os.sep) \
            and "migrate_volcanic_layers" not in _name:
        del sys.modules[_name]

from layers import volcanoes as volcano_layers          # noqa: E402
from layers.core import PlanetDb, open_layer            # noqa: E402

_SQL_TYPE = {"string": "text", "integer": "integer", "double": "double precision",
             "datetime": "timestamp"}

#: (old table, new table, INSERT column list, SELECT expression list)
COPIES = [
    ("active_volcano", "volcano",
     "geom, name, type, base_diameter_m, height_m, crater_diameter_m, has_lava_lake",
     "geom, name, CASE shape WHEN 'shield' THEN 'shield' WHEN 'caldera' THEN 'caldera' "
     "ELSE 'stratovolcano' END, base_diameter, height, crater_diameter, has_lava_lake"),
    ("lava_dome", "volcano",
     "geom, name, type, base_diameter_m",
     "geom, name, 'lava_dome', 2.0 * radius"),
    ("lava_river", "lava_flow",
     "geom, name, state, width_start_m, width_end_m",
     "geom, name, 'active', width_start, width_end"),
    ("fumarole", "fumarole_vent",
     "geom, name, radius, intensity",
     "geom, name, radius, intensity"),
]


def _planet_name():
    scope = QgsExpressionContextUtils.projectScope(QgsProject.instance())
    name = scope.variable("planet_name")
    if not name:
        raise RuntimeError("no planet_name project variable — open the planet project first")
    return str(name)


def migrate():
    planet = _planet_name()
    print("=" * 64)
    print(f"  Volcanic layers migration — planet '{planet}'")
    print("=" * 64)
    db = PlanetDb(planet)
    s = db.schema

    # 1-2. New tables, new columns.
    for layer_def in volcano_layers.CATEGORY.layers:
        if db.has_table(layer_def.table):
            for f in layer_def.fields:
                db.conn.executeSql(
                    f'ALTER TABLE "{s}"."{layer_def.table}" '
                    f'ADD COLUMN IF NOT EXISTS "{f.name}" {_SQL_TYPE[f.type]}')
            print(f"  · {s}.{layer_def.table}: columns checked")
        else:
            layer, _created = open_layer(db, layer_def)
            print(f"  · {s}.{layer_def.table}: created" if layer else
                  f"  ✗ {s}.{layer_def.table}: could not be created")

    # 3. Copy the old rows into the still-empty new tables.
    filled = {}
    for old, new, cols, select in COPIES:
        if not db.has_table(old):
            continue
        n_old = db.row_count(old)
        if n_old <= 0:
            print(f"  · {s}.{old}: empty, nothing to copy")
            continue
        if new not in filled:
            filled[new] = db.row_count(new) > 0
        if filled[new] and (old, new) not in filled:
            print(f"  ⚠ {s}.{new} already holds rows — {old} NOT copied (copy by hand if needed)")
            continue
        try:
            db.conn.executeSql(f'INSERT INTO "{s}"."{new}" ({cols}) SELECT {select} FROM "{s}"."{old}"')
            filled[(old, new)] = True
            print(f"  ✓ {s}.{old} → {s}.{new}: {n_old} row(s)")
        except Exception as e:  # noqa: BLE001 — a missing old column must not stop the rest
            print(f"  ✗ {s}.{old} → {s}.{new}: {e}")
    print("-" * 64)
    print("  Done. Check the new layers, re-run setup_planet_project.py, then drop")
    print("  the old tables (active_volcano, lava_dome, lava_river, fumarole) by hand.")
    print("=" * 64)


migrate()
