"""Build the DyingStar QGIS plugin zip and the plugins.xml of our plugin repository.

    python3 tools/planettech/qgis/package_plugin.py --out dist/
    python3 tools/planettech/qgis/package_plugin.py --out dist/ --tag qgis-plugin-v0.1.0 \\
        --download-url https://github.com/DyingStar-game/DyingStar/releases/download/qgis-plugin-v0.1.0/DyingStar-0.1.0.zip

The zip holds this folder as DyingStar/ (the name QGIS imports it under), without caches, the
personal export_config.ini and the export library's own tests. plugins.xml is the file QGIS
reads from a plugin repository (Plugins ▸ Manage and Install ▸ Settings ▸ Add…): one
<pyqgis_plugin> per plugin, with the zip's download URL. .github/workflows/qgis-plugin.yml runs
this on a `qgis-plugin-v<version>` tag. Python 3 stdlib only.
"""
import argparse
import configparser
import datetime
import os
import sys
import zipfile
from xml.sax.saxutils import escape, quoteattr

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN_NAME = "DyingStar"
TAG_PREFIX = "qgis-plugin-v"

#: Not shipped: caches, a personal config, the export library's tests and their goldens.
EXCLUDED_DIRS = {"__pycache__"}
EXCLUDED_FILES = {"export_config.ini", "package_plugin.py"}
EXCLUDED_SUFFIXES = (".pyc", ".pyo", ".orig", ".rej", "~")


def metadata(path=None):
    cp = configparser.ConfigParser(interpolation=None)
    cp.read(path or os.path.join(HERE, "metadata.txt"), encoding="utf-8")
    return dict(cp["general"])


def shipped_files(root=HERE):
    """Paths relative to [root] that go into the zip, sorted."""
    out = []
    for base, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in EXCLUDED_DIRS and not d.startswith("."))
        for name in files:
            if name in EXCLUDED_FILES or name.endswith(EXCLUDED_SUFFIXES) or name.startswith("."):
                continue
            rel = os.path.relpath(os.path.join(base, name), root)
            parts = rel.split(os.sep)
            if parts[0] == "export" and (name.startswith("test_") or name.endswith("_golden.json")):
                continue
            out.append(rel)
    return sorted(out)


def build_zip(out_dir, root=HERE):
    meta = metadata(os.path.join(root, "metadata.txt"))
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"{PLUGIN_NAME}-{meta['version']}.zip")
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        for rel in shipped_files(root):
            arc = PLUGIN_NAME + "/" + rel.replace(os.sep, "/")
            # A fixed date: the same sources give the same zip.
            info = zipfile.ZipInfo(arc, date_time=(2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            with open(os.path.join(root, rel), "rb") as fh:
                zf.writestr(info, fh.read())
    return path


def plugins_xml(meta, zip_name, download_url, date=None):
    date = date or datetime.date.today().isoformat()
    version = meta["version"]

    def el(tag, value):
        return f"    <{tag}>{escape(str(value))}</{tag}>\n"

    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        "<plugins>\n"
        f"  <pyqgis_plugin name={quoteattr(meta['name'])} version={quoteattr(version)}>\n"
        + el("description", meta.get("description", ""))
        + el("about", meta.get("about", ""))
        + el("version", version)
        + el("qgis_minimum_version", meta.get("qgisminimumversion", "4.0"))
        + el("qgis_maximum_version", meta.get("qgismaximumversion", "4.99"))
        + el("homepage", meta.get("homepage", ""))
        + el("file_name", zip_name)
        + el("author_name", meta.get("author", ""))
        + el("download_url", download_url)
        + el("uploaded_by", meta.get("author", ""))
        + el("create_date", date)
        + el("update_date", date)
        + el("experimental", meta.get("experimental", "False"))
        + el("deprecated", meta.get("deprecated", "False"))
        + el("tracker", meta.get("tracker", ""))
        + el("repository", meta.get("repository", ""))
        + el("tags", meta.get("tags", ""))
        + "  </pyqgis_plugin>\n"
        "</plugins>\n"
    )


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--out", required=True, help="output folder")
    ap.add_argument("--tag", help=f"the release tag; must be {TAG_PREFIX}<metadata version>")
    ap.add_argument("--download-url", help="where QGIS downloads the zip (plugins.xml)")
    args = ap.parse_args(argv)
    meta = metadata()
    if args.tag and args.tag != TAG_PREFIX + meta["version"]:
        print(f"tag {args.tag} does not match metadata.txt version {meta['version']} "
              f"(expected {TAG_PREFIX}{meta['version']})", file=sys.stderr)
        return 1
    path = build_zip(args.out)
    name = os.path.basename(path)
    url = args.download_url or ("file://" + os.path.abspath(path))
    with open(os.path.join(args.out, "plugins.xml"), "w", encoding="utf-8") as fh:
        fh.write(plugins_xml(meta, name, url))
    print(f"{path} ({os.path.getsize(path) / 1024:.0f} KB, {len(shipped_files())} files)")
    print(os.path.join(args.out, "plugins.xml"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
