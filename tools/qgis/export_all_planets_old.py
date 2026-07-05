"""
Export All Planets — Headless QGIS Batch Export
================================================
Opens each planet project from PostgreSQL, runs export_planet.py, and moves on.

Usage:
    /usr/bin/qgis_process run --no-sketcher -- \
        python3 tools/qgis/export_all_planets.py

    Or standalone (requires PyQGIS on PYTHONPATH):
        python3 tools/qgis/export_all_planets.py
"""

import os
import sys
import time

# Point QGIS at the real profile so the auth database and stored connections
# are found in headless mode.
os.environ.setdefault(
    "QGIS_CUSTOM_CONFIG_PATH",
    os.path.expanduser("~/.local/share/QGIS/QGIS3"),
)

# ============================================================
# PLANETS TO EXPORT
# ============================================================
# Each entry is the planet name. The PostgreSQL schema and the
# QGIS project name stored in that schema share the same name.
PLANETS = [
    "tarsis_1",
    "tarsis_2",
    "tarsis_3",
    "tarsis_3_1",
    "tarsis_4",
    "tarsis_4_1",
    "tarsis_4_2",
    "tarsis_5",
    "tarsis_5_1",
    "tarsis_5_2",
    "tarsis_5_3",
    "tarsis_5_4",
    "tarsis_5_5",
    "tarsis_5_6",
    "tarsis_6",
    "tarsis_6_1",
    "tarsis_6_2",
    "tarsis_7",
    "tarsis_8",
]

# PostgreSQL connection name configured in QGIS
PG_CONNECTION_NAME = "DyingStar"

# ============================================================
# QGIS HEADLESS INITIALISATION
# ============================================================
from qgis.core import (
    QgsApplication,
    QgsProject,
    QgsDataSourceUri,
)

app = QgsApplication([], False)  # False = no GUI
app.setPrefixPath("/usr", True)
app.initQgis()

# Add QGIS plugin path so the Processing framework can be imported.
_qgis_plugins = os.path.join(app.pkgDataPath(), "python", "plugins")
if _qgis_plugins not in sys.path:
    sys.path.insert(0, _qgis_plugins)

# Initialise the QGIS Processing framework (needed by export_planet.py
# for rasterization and other geoprocessing calls).
import processing
from processing.core.Processing import Processing
Processing.initialize()

_SENTINEL = object()  # unique marker for sys.modules save/restore

# Initialise the auth manager so that authcfg credentials stored in the
# encrypted QGIS auth database can be resolved in headless mode.
_auth_mgr = app.authManager()
if not _auth_mgr.masterPasswordHashInDatabase():
    print("WARNING: No master password set in QGIS auth database — authcfg will not resolve.")
    print("  You may need to set a master password in QGIS GUI first.")
else:
    import getpass
    master_pw = getpass.getpass("Enter QGIS auth master password: ")
    if not _auth_mgr.setMasterPassword(master_pw, verify=True):
        print("ERROR: Failed to unlock QGIS auth database. authcfg will not resolve.")
    else:
        print("  Auth database unlocked.")

# Path to the export script (lives next to this file)
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
EXPORT_SCRIPT_PATH = os.path.join(_THIS_DIR, "export_planet.py")

if not os.path.isfile(EXPORT_SCRIPT_PATH):
    print(f"ERROR: export_planet.py not found at {EXPORT_SCRIPT_PATH}")
    app.exitQgis()
    sys.exit(1)


def _read_pg_settings():
    """Read PostgreSQL connection parameters from the QGIS3 profile INI file.

    In headless mode QgsSettings may not find stored connections because it
    does not always load the correct profile.  We read the INI directly
    from the default profile location as a reliable fallback.
    Returns a dict with host, port, database, username, password, service,
    sslmode, authcfg.
    """
    import configparser

    ini_path = os.path.expanduser(
        "~/.local/share/QGIS/QGIS3/profiles/default/QGIS/QGIS3.ini"
    )
    if not os.path.isfile(ini_path):
        raise RuntimeError(
            f"QGIS profile INI not found at {ini_path}\n"
            "  Make sure QGIS has been run at least once to create a profile."
        )

    cfg = configparser.ConfigParser()
    cfg.read(ini_path)

    section = "PostgreSQL"
    if not cfg.has_section(section):
        raise RuntimeError(
            f"No [PostgreSQL] section found in {ini_path}\n"
            "  → Add a connection via QGIS: Layer → Data Source Manager → PostgreSQL → New"
        )

    prefix = f"connections\\{PG_CONNECTION_NAME}\\"
    # Collect all keys for this connection
    conn_keys = {
        k[len(prefix):]: v
        for k, v in cfg.items(section)
        if k.startswith(prefix.lower())  # configparser lowercases keys
    }
    if not conn_keys:
        # List available connections
        all_keys = [k for k in cfg.options(section) if k.startswith("connections\\")]
        names = sorted({k.split("\\")[1] for k in all_keys}) if all_keys else []
        available = ", ".join(names) or "(none)"
        raise RuntimeError(
            f"PostgreSQL connection '{PG_CONNECTION_NAME}' not found in QGIS profile.\n"
            f"  Available connections: {available}\n"
            "  → Add it via: Layer menu → Data Source Manager → PostgreSQL → New"
        )

    return {
        "host": conn_keys.get("host", "localhost"),
        "port": conn_keys.get("port", "5432"),
        "database": conn_keys.get("database", ""),
        "username": conn_keys.get("username", ""),
        "password": conn_keys.get("password", ""),
        "service": conn_keys.get("service", ""),
        "sslmode": conn_keys.get("sslmode", ""),
        "authcfg": conn_keys.get("authcfg", ""),
    }


def _build_pg_project_uri(planet_name):
    """Build the full PostgreSQL URI to open a QGIS project stored in PostGIS.

    Reads host/port/dbname/credentials from QgsSettings (the same values
    configured in QGIS GUI) and constructs the URI that QgsProject.read()
    expects, e.g.:
        postgresql://user@host:port?dbname=DB&schema=SCHEMA&project=PROJECT
    """
    pg = _read_pg_settings()

    from urllib.parse import urlencode, quote

    userinfo = ""
    if pg["username"]:
        userinfo = quote(pg["username"], safe="")
        if pg["password"]:
            userinfo += ":" + quote(pg["password"], safe="")
        userinfo += "@"

    host = pg["host"] or "localhost"
    port_part = f":{pg['port']}" if pg["port"] else ""

    params = {}
    if pg["service"]:
        params["service"] = pg["service"]
    if pg["database"]:
        params["dbname"] = pg["database"]
    params["schema"] = planet_name
    params["project"] = planet_name
    if pg["authcfg"]:
        params["authcfg"] = pg["authcfg"]
    if pg["sslmode"] and pg["sslmode"] != "1":  # 1 = SslPrefer (default)
        params["sslmode"] = pg["sslmode"]

    query = urlencode(params)
    return f"postgresql://{userinfo}{host}{port_part}?{query}"


def export_planet(planet_name):
    """Open a planet project from PostgreSQL and run export_planet.py."""
    project = QgsProject.instance()

    uri = _build_pg_project_uri(planet_name)
    print(f"  Opening project: {uri}")

    if not project.read(uri):
        err = project.error()
        raise RuntimeError(
            f"Failed to open project for '{planet_name}' from PostgreSQL.\n"
            f"  URI: {uri}\n"
            f"  QGIS error: {err}\n"
            f"  Check that the schema and project exist in the "
            f"'{PG_CONNECTION_NAME}' database."
        )

    print(f"  Project loaded: {project.title() or planet_name}")

    # exec() in a fresh namespace so globals from one planet don't leak
    # into the next.  The script reads PLANET_NAME from the loaded project.
    with open(EXPORT_SCRIPT_PATH, "r") as f:
        code = f.read()

    # Block the import of setup_planet_project.  Importing it runs its
    # module-level code which calls iface.mapCanvas() — that crashes in
    # headless mode.  Setting the module to None in sys.modules makes
    # "from setup_planet_project import ..." raise ImportError, causing
    # export_planet.py to use its hardcoded fallback constants.
    _saved_module = sys.modules.get("setup_planet_project", _SENTINEL)
    sys.modules["setup_planet_project"] = None
    try:
        exec(compile(code, EXPORT_SCRIPT_PATH, "exec"), {
            "__name__": "__export__",
            "__file__": EXPORT_SCRIPT_PATH,
        })
    finally:
        if _saved_module is _SENTINEL:
            sys.modules.pop("setup_planet_project", None)
        else:
            sys.modules["setup_planet_project"] = _saved_module

    project.clear()
    print(f"  Project closed: {planet_name}\n")


# ============================================================
# MAIN
# ============================================================
def main():
    total = len(PLANETS)
    results = []  # (planet_name, success, elapsed, error_msg)

    print("=" * 60)
    print(f"  Batch export — {total} planet(s)")
    print("=" * 60)

    for idx, planet_name in enumerate(PLANETS, start=1):
        print(f"\n[{idx}/{total}] Exporting {planet_name}...")
        t0 = time.time()
        try:
            export_planet(planet_name)
            elapsed = time.time() - t0
            results.append((planet_name, True, elapsed, ""))
            print(f"  ✓ {planet_name} done in {elapsed:.1f}s")
        except Exception as exc:
            elapsed = time.time() - t0
            results.append((planet_name, False, elapsed, str(exc)))
            print(f"  ✗ {planet_name} FAILED after {elapsed:.1f}s: {exc}")
            # Clear the project to avoid stale state for the next planet
            QgsProject.instance().clear()

    # ── Summary ──
    succeeded = [r for r in results if r[1]]
    failed = [r for r in results if not r[1]]
    total_time = sum(r[2] for r in results)

    print("\n" + "=" * 60)
    print(f"  Batch export finished in {total_time:.1f}s")
    print(f"  Succeeded: {len(succeeded)}/{total}")
    if failed:
        print(f"  Failed:    {len(failed)}/{total}")
        for name, _, elapsed, err in failed:
            print(f"    - {name} ({elapsed:.1f}s): {err}")
    print("=" * 60)

    return len(failed) == 0


if __name__ == "__main__":
    try:
        success = main()
    finally:
        app.exitQgis()
    sys.exit(0 if success else 1)
