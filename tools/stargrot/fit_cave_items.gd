extends Node
## Fits the caves exported from QGIS (tools/planettech/qgis/export_cave_sites.py) to the CURRENT terrain and
## writes the file the admin panel imports into the persistence: one networked "cave" prop (CaveSite) each.
##
##   <godot> --headless --path <repo> res://tools/stargrot/fit_cave_items.tscn -- \
##       --in=<dir>/<planet>_cave_sites.json [--out=<dir>/<planet>_cave_items.json] [--parent=_planet_SandBox] \
##       [--jobs=<caves fitted at once, default half the CPU threads>]
##
## A cave is pinned to one relief: its mouth depth, network offset, porch and light shafts are measured on the
## terrain (CaveFitter.refit, the workbench's "Recaler"), and a cave measured on another relief is refused by
## the game. Run this again after every terrain re-export, then import again: the prop uuids derive from the
## placement ids, so the import updates the caves instead of adding new ones.
##
## The server fits a cave itself when a player comes near it (CaveSite), so this step is optional: it checks
## the caves before the import (the refused ones are listed) and spares the server the fit. Each fit is saved
## as it ends in <out>_checkpoint.json: run the same command again after a crash or an interruption and only the
## caves not fitted yet are measured. A checkpoint entry is reused while the relief and the cave's QGIS parameters
## are unchanged.
##
## A porch on a real slope is turned to face uphill whatever heading QGIS gave it (CaveFitter.prepare_site):
## the imported heading is the fitted one. Caves refused by the fit, or too close to a cave already accepted, are
## left out of the import and listed, with the reason, in <out>_rejected.json.

## The scene of a networked cave, as the persistence stores it (no res:// prefix).
const SCENE := "scenes/planet/cave/cave_site.tscn"
## Horizon alias of each planet's object, the parent of its caves (admin panel: _<type>_<name>).
const PARENT_ALIASES := {"tarsis_3": "_planet_SandBox"}

var _status := 0
var _pending: Array[int] = []
var _running := 0
var _done := 0


func _ready() -> void:
    _run.call_deferred()


func _run() -> void:
    var args := _args()
    var input := str(args.get("in", ""))
    var authored: Variant = JSON.parse_string(FileAccess.get_file_as_string(input)) if FileAccess.file_exists(input) else null
    if not (authored is Dictionary) or not ((authored as Dictionary).get("sites") is Array):
        _fail("--in=<fichier>_cave_sites.json (export_cave_sites.py) attendu, reçu '%s'" % input)
        return
    var planet_name := str(authored.get("planet_name", ""))
    var parent := str(args.get("parent", PARENT_ALIASES.get(planet_name, "")))
    if parent.is_empty():
        _fail("pas d'alias Horizon connu pour '%s' : passer --parent=_planet_<nom>" % planet_name)
        return
    var output := str(args.get("out", input.get_base_dir().path_join("%s_cave_items.json" % planet_name)))

    var data := _planet_data(planet_name)
    if data == null:
        _fail("planète '%s' introuvable dans le système tarsis" % planet_name)
        return
    var terrain := PlanetTerrain.new()
    terrain.name = "FitTerrain"
    add_child(terrain)
    terrain.initialize(data, true)
    terrain.set_process(false)
    terrain.set_physics_process(false)

    var rejected: Dictionary = {}
    var sites: Array[CavePlacement] = []
    var keys: Array[String] = []
    for entry: Variant in authored.sites:
        var site := CavePlacement.from_prop_data(entry if entry is Dictionary else {})
        if site == null:
            rejected[str((entry as Dictionary).get("placement_id", "?")) if entry is Dictionary else "?"] = \
                "champs requis manquants (%s)" % ", ".join(CavePlacement.PROP_REQUIRED)
            continue
        site.planet_name = planet_name
        sites.append(site)
        keys.append(JSON.stringify(entry, "", true, true).sha256_text())

    var checkpoint_path := output.get_basename() + "_checkpoint.json"
    var checkpoint := _checkpoint(checkpoint_path, data)
    var todo: Array[int] = []
    for index in sites.size():
        var saved: Dictionary = checkpoint.sites.get(sites[index].placement_id, {})
        if saved.get("authored") != keys[index]:
            todo.append(index)
    var reused := sites.size() - todo.size()
    @warning_ignore("integer_division")
    var jobs := clampi(int(args.get("jobs", OS.get_processor_count() / 2)), 1, 64)
    print("[fit_cave_items] %d grottes à recaler, %d reprises du point de reprise, %d à la fois" % [
        todo.size(), reused, jobs])
    var started := Time.get_ticks_msec()
    _pending = todo.duplicate()
    for job in mini(jobs, todo.size()):
        var fitter := CaveFitter.new()
        add_child(fitter)
        _fit_next(fitter, data, sites, keys, checkpoint, checkpoint_path, todo.size())
    while _running > 0 or not _pending.is_empty():
        await get_tree().process_frame
    print("[fit_cave_items] recalage en %.1f s" % ((Time.get_ticks_msec() - started) / 1000.0))

    var fitted: Array[CavePlacement] = []
    for site in sites:
        var saved: Dictionary = checkpoint.sites.get(site.placement_id, {})
        var back := CavePlacement.from_prop_data(saved.get("fitted", {})) if saved.has("fitted") else null
        if back == null:
            rejected[site.placement_id] = str(saved.get("error", "recalage illisible"))
            continue
        back.resource_name = site.resource_name
        fitted.append(back)
    print("[fit_cave_items] %d grottes sur %s (relief %s), %d reprises du point de reprise" % [
        sites.size(), planet_name, data.relief_signature, reused])

    var items: Array = []
    var accepted: Dictionary = {}
    for site: CavePlacement in fitted:
        var footprint := site.footprint_bounds()
        var neighbour := ""
        for other: String in accepted:
            if footprint.intersects(accepted[other]):
                neighbour = other
                break
        if not neighbour.is_empty():
            rejected[site.placement_id] = "trop proche de la grotte %s" % neighbour
            continue
        accepted[site.placement_id] = footprint
        items.append(_item(site, parent))

    _write(output, items)
    var rejected_path := output.get_basename() + "_rejected.json"
    _write(rejected_path, rejected)
    print("[fit_cave_items] %d grottes -> %s ; %d refusées -> %s" % [items.size(), output, rejected.size(), rejected_path])
    get_tree().quit(_status)


## One fitter's loop: fit the next pending cave, save it in the checkpoint, until none is left.
func _fit_next(fitter: CaveFitter, data: PlanetData, sites: Array[CavePlacement], keys: Array[String],
        checkpoint: Dictionary, checkpoint_path: String, total: int) -> void:
    _running += 1
    while not _pending.is_empty():
        var index: int = _pending.pop_front()
        var site := sites[index]
        var report: Dictionary = await fitter.refit(data, [site] as Array[CavePlacement])
        var saved := {"authored": keys[index]}
        if report.sites.is_empty():
            saved["error"] = ", ".join(report.rejected.keys()).trim_prefix(site.placement_id + " : ")
        else:
            saved["fitted"] = (report.sites[0] as CavePlacement).to_prop_data()
        checkpoint.sites[site.placement_id] = saved
        _write(checkpoint_path, checkpoint)
        _done += 1
        if _done % 10 == 0 or _done == total:
            print("[fit_cave_items] %d / %d recalées" % [_done, total])
    _running -= 1


## The fits already measured on this relief: {relief, terrain_version, sites: {placement_id: {authored, fitted|error}}}.
static func _checkpoint(path: String, data: PlanetData) -> Dictionary:
    var fresh := {"relief": data.relief_signature, "terrain_version": data.chunk_data_version, "sites": {}}
    var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
    if not (saved is Dictionary) or not ((saved as Dictionary).get("sites") is Dictionary):
        return fresh
    if saved.get("relief") != fresh.relief or saved.get("terrain_version") != fresh.terrain_version:
        print("[fit_cave_items] point de reprise d'un autre relief, ignoré : %s" % path)
        return fresh
    return saved


## The persistence import entry of a fitted cave: a "cave" prop on its planet, standing on its entrance point.
static func _item(site: CavePlacement, parent: String) -> Dictionary:
    var frame := site.surface_transform()  # the terrain frame is the planet's: PlanetTerrain sits at its origin
    var euler := frame.basis.get_euler()
    var data := site.to_prop_data()
    data.merge({
        "name": site.resource_name if not site.resource_name.is_empty() else site.placement_id,
        "parent_id": parent,
        "scenename": SCENE,
        "position": {"x": frame.origin.x, "y": frame.origin.y, "z": frame.origin.z},
        "rotation": {"x": euler.x, "y": euler.y, "z": euler.z},
        CaveSite.FIT_ERROR: {},  # clears a refusal the server persisted for an older definition
    })
    return {"object_type": "cave", "object_uuid": PropSpawn.stable_uuid("cave:" + site.placement_id),
        "object_data": data}


## The planet's data as the game scene states it, without any catalog: the caves under test are the only ones.
static func _planet_data(planet_name: String) -> PlanetData:
    var path := SystemScenes.body_path("tarsis", planet_name)
    if not ResourceLoader.exists(path):
        return null
    var data: PlanetData = (SystemScenes.root_properties(path).planet_data as PlanetData).duplicate(true)
    data.cave_catalog = null
    data.cave_placements.clear()
    return data


func _write(path: String, value: Variant) -> void:
    DirAccess.make_dir_recursive_absolute(path.get_base_dir())
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        _fail("écriture impossible : %s" % path)
        return
    file.store_string(JSON.stringify(value, "\t", false, true) + "\n")
    file.close()


func _fail(message: String) -> void:
    push_error("[fit_cave_items] " + message)
    _status = 1
    get_tree().quit(1)


static func _args() -> Dictionary:
    var out := {}
    for arg in OS.get_cmdline_user_args():
        if arg.begins_with("--") and arg.contains("="):
            var pair := arg.trim_prefix("--").split("=", true, 1)
            out[pair[0]] = pair[1]
    return out
