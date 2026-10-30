class_name CaveSiteCollection
extends Resource
## Local authoring session. The game consumes its CavePlacement entries, not this collection.

## Local authoring collection format; version 1 is supported.
@export var format_version: int = 1
## Locally saved authored sites across planets; exporting selects only the current planet.
@export var sites: Array[CavePlacement] = []
## Stable identifier of the currently selected site; empty means no selection.
@export var selected_id: String = ""


func validation_error() -> String:
    if format_version != 1:
        return "Version de collection inconnue."
    var ids: Dictionary = {}
    for site in sites:
        if site == null:
            return "Un site est absent de la collection."
        var error := site.definition_error()
        if not error.is_empty():
            return error
        if ids.has(site.placement_id):
            return "Deux grottes portent le même identifiant."
        ids[site.placement_id] = true
    if not selected_id.is_empty() and not ids.has(selected_id):
        return "La grotte sélectionnée ne figure pas dans la collection."
    return ""


func selected() -> CavePlacement:
    for site in sites:
        if site.placement_id == selected_id:
            return site
    return null


func on_body(key: String) -> Array[CavePlacement]:
    var result: Array[CavePlacement] = []
    for site in sites:
        if site.planet_name == key:
            result.append(site)
    return result


func put(site: CavePlacement) -> void:
    for index in sites.size():
        if sites[index].placement_id == site.placement_id:
            sites[index] = site
            selected_id = site.placement_id
            return
    sites.append(site)
    selected_id = site.placement_id


func remove_selected() -> void:
    for index in sites.size():
        if sites[index].placement_id == selected_id:
            sites.remove_at(index)
            selected_id = sites[mini(index, sites.size() - 1)].placement_id if not sites.is_empty() else ""
            return


func remove_on_body(key: String) -> void:
    sites = sites.filter(func(site: CavePlacement): return site.planet_name != key)
    if selected() == null:
        selected_id = sites[0].placement_id if not sites.is_empty() else ""


func save_to(path: String) -> Error:
    if not validation_error().is_empty():
        return ERR_INVALID_DATA
    return CaveAuthoringFile.save(self, path)


## Replace dressing only: preserve every placement, seed, geometry and terrain fit.
## Unchanged sites and all heavy art resources remain shared.
func with_library(planet_key: String, library: CaveAssetLibrary, selected_only: bool) -> CaveSiteCollection:
    var next: CaveSiteCollection = duplicate()
    next.sites = sites.duplicate()
    for index in sites.size():
        var site := sites[index]
        if site.planet_name != planet_key or (selected_only and site.placement_id != selected_id) \
                or site.profile.profile_id != library.surface_family:
            continue
        var changed: CavePlacement = site.duplicate()
        changed.profile = site.profile.duplicate()
        changed.profile.asset_library = library
        next.sites[index] = changed
    return next
