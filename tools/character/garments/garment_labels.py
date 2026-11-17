"""Register a garment in the catalogue, and name every garment in the creator: %%GARMENT_<ID> in
tools/localization/localisation.csv, from the English and French names its file carries (name_en / name_fr, set in the Blender add-on), and the entry's
"label" in human_catalogue.json (the localisation test sees a key used there).

The %%GARMENT_ block of the CSV is rewritten whole; run it after adding a garment (the add-on's export does, through
add_to_catalogue and write_labels).

usage: python3 tools/character/garments/garment_labels.py <project root>
"""
import csv
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import garment_bind as gb  # noqa: E402

GARMENTS_REL = "assets/_universe/characters/human/garments"
CATALOGUE_REL = "assets/_universe/characters/human/human_catalogue.json"
PREFIX = "%%GARMENT_"


def label_of(garment_id):
    return PREFIX + "".join(c if c.isalnum() else "_" for c in garment_id).upper()


CATALOGUE_FIELDS = ("id", "zones", "support", "layer", "access", "hides", "material", "gender")
ORDER_REL = "test/data/character/catalogue_order.json"


def add_to_catalogue(root, meta):
    """The garment of `meta` (a .dsgarment's meta) in human_catalogue.json: its entry updated in place when it is
    there, else appended at the end -- and appended to the frozen order the tests check (catalogue_order.json).
    Returns its position (what a look stores)."""
    path = os.path.join(root, CATALOGUE_REL)
    catalogue = json.load(open(path, encoding="utf-8"))
    entries = catalogue.setdefault("garments", [])
    entry = {k: meta[k] for k in CATALOGUE_FIELDS}
    entry["label"] = label_of(meta["id"])
    found = next((i for i, e in enumerate(entries) if e["id"] == meta["id"]), None)
    if found is None:
        entries.append(entry)
        found = len(entries) - 1
    else:
        entries[found] = entry
    with open(path, "w", encoding="utf-8") as f:
        json.dump(catalogue, f, indent=1, ensure_ascii=False)
        f.write("\n")
    order_path = os.path.join(root, ORDER_REL)
    if os.path.exists(order_path):
        order = json.load(open(order_path, encoding="utf-8"))
        if meta["id"] not in order.setdefault("garments", []):
            order["garments"].append(meta["id"])
            with open(order_path, "w", encoding="utf-8") as f:
                json.dump(order, f, indent=1, ensure_ascii=False)
                f.write("\n")
    return found


def write_labels(root):
    """%%GARMENT_<ID> of every catalogue garment in localisation.csv, from the names its file carries."""
    catalogue_path = os.path.join(root, CATALOGUE_REL)
    catalogue = json.load(open(catalogue_path, encoding="utf-8"))
    rows = []
    for entry in catalogue.get("garments", []):
        path = os.path.join(root, GARMENTS_REL, entry["id"], entry["id"] + ".dsgarment")
        if not os.path.exists(path):
            raise FileNotFoundError("no garment file for %s: %s" % (entry["id"], path))
        _arrays, meta = gb.read_garment(path)
        entry["label"] = label_of(entry["id"])
        rows.append([entry["label"], meta.get("name_en") or entry["id"], meta.get("name_fr") or meta.get("name_en")
                     or entry["id"]])
    with open(catalogue_path, "w", encoding="utf-8") as f:
        json.dump(catalogue, f, indent=1, ensure_ascii=False)
        f.write("\n")
    csv_path = os.path.join(root, "tools/localization/localisation.csv")
    with open(csv_path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    while lines and lines[-1] == "":
        lines.pop()
    columns = len(next(csv.reader([lines[0]])))
    kept = [line for line in lines if not line.startswith(PREFIX)]
    out = io.StringIO()
    csv.writer(out, lineterminator="\n").writerows(r + [""] * (columns - 3) for r in rows)
    with open(csv_path, "w", encoding="utf-8", newline="") as f:
        f.write("\n".join(kept) + "\n" + out.getvalue())
    return len(rows)


def main():
    root = sys.argv[1]
    print("%d garment names written to %s" % (write_labels(root), os.path.join(root, "tools/localization/localisation.csv")))


if __name__ == "__main__":
    main()
