# Character sheets: format and versions

This is the format the game sends to and reads from the backend for a player's characters. A player can have
several characters. The backend stores each one as a **sheet** and does not need to understand the look inside
it. The game owns the format and its upgrades.

## The sheet

The game sends (POST/PUT):

```json
{
  "name": "Ada",
  "appearance": { "format": "dyingstar.character", "version": 2, "...": "the look, see below" },
  "appearance_version": 2,
  "thumbnail": "<WebP image, 256 x 256, base64 (about 4-6 KB)>",
  "filters": { "gender": "female", "age": 34, "origin": "Race_White", "hair": "bob", "beard": "none" }
}
```

The backend adds `id`, `created_at` and `updated_at`. It sends the sheet back with every field the game
sent, unchanged. The game keeps any field it does not know and sends it back on save.

| Field | Who owns it | Notes |
|---|---|---|
| `appearance` | game | The source of truth. Store it as an opaque JSON blob. |
| `appearance_version` | game | Same value as `appearance.version`. Index it: it finds the sheets an upgrade will touch. |
| `name` | player | May be empty. |
| `thumbnail` | game | Derived from the look and rendered again on every save. |
| `filters` | game | Derived from the look and computed again on every save. Index the keys you want to filter on. More keys may come, and a key's meaning never changes. |
| `id`, `created_at`, `updated_at` | backend | |

Which character is worn in game is still sent separately, as the player's replicated `appearance`
(see "Two forms" below).

## The look (`appearance`)

Every choice is stored **by name**:
- a slider by its key;
- a hair style, beard, eyebrows, garment or eye colour by its catalogue id (`"garments": [{"id": ..., "tint": 0}]`,
  what the character wears, by the GDD's zones and layers);
- an origin by its name;
- a hair parting, hair tie or beard shape by its enum name.

A reordered or extended catalogue therefore never changes a saved character. Values are numbers from 0 to 1
(sliders from -1 to 1), rounded to 0.001. The frozen samples `test/data/character/v1.json` and `v2.json` show a full
document.

Reading is forgiving:
- a missing field takes its default;
- an unknown name (a slider or style removed since) is skipped with a warning.

Only two things are refused:
- a document of another `format`;
- a document whose `version` is **newer than the game's**. It is never cut down, so an old client cannot
  damage what a newer client wrote.

## Versions

`appearance.version` is an integer, currently **2**. It changes only for a **breaking** change:
- a rename;
- a removal that must be carried over to something else;
- a field whose meaning or scale changes.

Adding a slider, style, garment or field does **not** change the version.

| Version | What changed |
|---|---|
| 1 | First version: one `outfit` (a MakeHuman suit and its shoes). |
| 2 | `garments` replaces `outfit`: a list of garments. Version 1's outfit becomes the garments the catalogue lists for it (`assets.outfit[i].garments`). |

Each version adds one pure step, `Dictionary -> Dictionary`, in `CharacterMigrations`
(`scenes/_universe/characters/human/character_migrations.gd`). Steps are chained, so any old document
reaches the current version. Steps are never removed.

For now the **game** upgrades on read. A sheet it reads in an older version is upgraded in memory, and written
back at the current version the next time it is saved.

### Upgrading the stored sheets in bulk

For an admin, before or after a release that raised the version:

```
godot --headless --path . res://tools/character/convert_characters.tscn -- --in=<export file or folder> --out=<folder> [--check]
```

**Input:**
- `.json` files holding one sheet, one document, or an array of either;
- `.txt` files of old look codes, one per line.

**Output:**
- Each file is written again under `--out`, in the same shape, at the current version.
- Each sheet keeps its `id`, `name`, dates and `thumbnail`.
- `report.json` gives:
  - the number of items per original version;
  - the warnings (unknown names);
  - the refused items, which are written back untouched.
- The exit code is 1 if any item was refused.

**Option `--check`:** reads and reports only, and writes nothing.

A direct mode (read and write through the API with an admin token) can be added once the API contract is fixed.

## Two forms of the same look

| | Sheet / document (this file) | Replicated string |
|---|---|---|
| Where | Backend, export and import | Network, Horizon's saved player |
| Form | JSON, named | About 200 characters of base64url, positions in `human_catalogue.json` |
| Versioning | `version` + `CharacterMigrations` | Byte 0, read back to v2 by `CharacterAppearance.from_bytes` |

Because the replicated string stores positions, `human_catalogue.json` is **append-only**:
- `test/unit/test_catalogue_order.gd` checks it;
- the tools that write it stop when an entry would move (`tools/character/human_bank/catalogue_guard.py`).

`CharacterDocument.parse()` also reads replicated strings, so old saves and shared codes import as they are.

## In the game

- `CharacterDocument`: look to JSON and back, and `parse()`.
- `CharacterMigrations`: the steps between versions.
- `CharacterSheet`: `make()`, `read()`, `upgrade()`, `filters_of()`, `thumbnail_of()`.
- `CharacterLibrary` (`scenes/globals/character_library.gd`):
  - `list()`, `fetch(id)`, `save(sheet)`, `remove(id)`, always awaited;
  - today: a local folder, `user://characters`;
  - the backend's HTTP client plugs in as `CharacterLibrary.backend`.
