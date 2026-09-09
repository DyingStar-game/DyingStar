"""
The per-planet, APPEND-ONLY string table shared by every modifier exporter.

Records store u16 ids instead of strings: "volcanic_geothermal-mineral_thermal_source"
is 43 bytes and repeats in tens of thousands of tiles; an id is 2.

The table lives in <planet>_chunks/parts/strings.json and every exporter interns
into the SAME file. The append-only rule is what makes link_modifiers.py trivial:
because an id, once assigned, never moves, ids in a part written last week are
still valid against a table extended today, so the linker copies record blocks
byte for byte and never has to re-encode anything. Reordering or compacting this
file invalidates every existing part — see link_modifiers.compact_strings(),
which is the only supported way to do it and which reprocesses all parts.

Pure stdlib, no QGIS import.
"""
import json
import os

#: u16 id meaning "absent". Also the hard cap on table size.
SID_NONE = 0xFFFF
MAX_STRINGS = 0xFFFF


class StringTable(object):
    """Append-only intern table mapping str <-> u16 id."""

    def __init__(self, strings=None):
        self._strings = list(strings or [])
        self._index = {}
        for i, s in enumerate(self._strings):
            # First occurrence wins: a duplicate in a hand-edited file must not
            # silently remap the lower id.
            self._index.setdefault(s, i)
        self._dirty = False

    # ── intern ────────────────────────────────────────────────────────

    def intern(self, s):
        """Return the id for [s], appending it if new. None/"" -> SID_NONE."""
        if s is None:
            return SID_NONE
        s = str(s)
        if s == "":
            return SID_NONE
        got = self._index.get(s)
        if got is not None:
            return got
        if len(self._strings) >= MAX_STRINGS:
            raise ValueError(
                "string table is full (%d entries); the u16 id space is "
                "exhausted" % MAX_STRINGS)
        sid = len(self._strings)
        self._strings.append(s)
        self._index[s] = sid
        self._dirty = True
        return sid

    def get(self, sid):
        """Resolve an id back to its string. Out-of-range ids resolve to ""."""
        if sid is None or sid == SID_NONE or sid < 0 or sid >= len(self._strings):
            return ""
        return self._strings[sid]

    def as_list(self):
        return list(self._strings)

    @property
    def dirty(self):
        return self._dirty

    def __len__(self):
        return len(self._strings)

    def __contains__(self, s):
        return s in self._index

    # ── persistence ───────────────────────────────────────────────────

    @staticmethod
    def path_for(parts_dir):
        return os.path.join(parts_dir, "strings.json")

    @classmethod
    def load(cls, parts_dir):
        """Load the table for [parts_dir], or an empty one if absent."""
        p = cls.path_for(parts_dir)
        if not os.path.exists(p):
            return cls()
        with open(p, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        if not isinstance(data, list):
            raise ValueError("%s must contain a JSON array of strings" % p)
        return cls(data)

    def save(self, parts_dir, force=False):
        """Persist the table. No-op when nothing was interned, unless [force].

        Written atomically so a crashed export cannot leave a table that
        disagrees with the parts already on disk.
        """
        if not self._dirty and not force:
            return None
        os.makedirs(parts_dir, exist_ok=True)
        p = self.path_for(parts_dir)
        tmp = p + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(self._strings, fh, ensure_ascii=False, indent=1)
            fh.write("\n")
        os.replace(tmp, p)
        self._dirty = False
        return p

    def assert_extends(self, older):
        """Raise unless this table is a prefix-preserving extension of [older].

        The invariant every part on disk depends on. Call it before writing a
        table that was loaded, mutated and is about to overwrite the old one.
        """
        prev = older.as_list() if isinstance(older, StringTable) else list(older)
        if len(prev) > len(self._strings):
            raise ValueError(
                "string table shrank from %d to %d entries — every existing "
                "part's ids would be invalidated" % (len(prev), len(self._strings)))
        for i, s in enumerate(prev):
            if self._strings[i] != s:
                raise ValueError(
                    "string id %d changed from %r to %r — the table is "
                    "append-only" % (i, s, self._strings[i]))
