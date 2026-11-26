"""What the tile service's channels serve, read over HTTP like the game does
(<http>/channels/<channel>.json), and which modifier pack a line-profile bake was made for.

Used by the plugin's « Promouvoir… » (versions on both sides, profiles that do not match the pack)
and by bake_lines.py (records the pack it baked against).
"""
import json
import os
import urllib.request

ORDER = ["unstable", "dev", "preprod", "prod"]
#: Written by bake_lines.py beside grade_profiles.pack: {"mod": <planet>.mod version baked against,
#: "channel": …, "sha256": … of the pack}.
BAKE_RECORD = "grade_profiles.json"


def http_base():
    """The tile service's URL: the publication settings', else client.ini's tiles_url."""
    import link_modifiers
    return (link_modifiers._publish_remote().load_config().get("http") or "").rstrip("/")


def read(channel, base=None, timeout=8.0):
    """{body: data_version} served on [channel]; raises on a network error."""
    base = http_base() if base is None else base
    if not base:
        raise RuntimeError("no tile-service URL (DyingStar ▸ Paramètres ▸ URL HTTP)")
    req = urllib.request.Request(f"{base}/channels/{channel}.json",
                                 headers={"Cache-Control": "no-cache"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        doc = json.loads(resp.read().decode("utf-8"))
    return {body: str(e.get("data_version", "")) for body, e in doc.get("planets", {}).items()}


def previous(channel):
    i = ORDER.index(channel)
    return ORDER[i - 1] if i > 0 else None


def sha256(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def write_bake_record(chunks_dir, mod_version, channel):
    pack = os.path.join(chunks_dir, "grade_profiles.pack")
    with open(os.path.join(chunks_dir, BAKE_RECORD), "w", encoding="utf-8") as fh:
        json.dump({"mod": mod_version, "channel": channel, "sha256": sha256(pack)}, fh, indent=2)


def lines_verdict(chunks_dir, planet, served):
    """Do the line profiles [served] on a channel match its modifier pack?

    True / False, or None when this machine cannot tell (profiles baked elsewhere, or before the
    record existed). Known only for the bake this machine published last: its record names the
    pack it was baked against, its .published.json the version it went out as."""
    lines, mod = served.get(f"{planet}.lines"), served.get(f"{planet}.mod")
    if not lines or not mod:
        return None
    try:
        with open(os.path.join(chunks_dir, BAKE_RECORD), encoding="utf-8") as fh:
            rec = json.load(fh)
        with open(os.path.join(chunks_dir, ".published.json"), encoding="utf-8") as fh:
            pub = json.load(fh).get("grade_profiles.pack", {})
    except (OSError, ValueError):
        return None
    pack = os.path.join(chunks_dir, "grade_profiles.pack")
    if pub.get("version") != lines or not os.path.exists(pack) or sha256(pack) != rec.get("sha256"):
        return None
    return rec.get("mod") == mod
