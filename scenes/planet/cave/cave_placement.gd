@tool
class_name CavePlacement
extends Resource
## Authored, body-fixed placement. Elevation is pinned to one terrain version,
## never to the observer's current LOD. The identifier survives edits.

## Stable site identifier, unique on the planet; editing dimensions must preserve it.
@export var placement_id: String = "stargrot-manual-001"
## Target planet identifier; must match PlanetData.planet_name.
@export var planet_name: String = "tarsis_3"
## Body-fixed longitude (deg); format 2 uses the native geographic convention, format 1 its legacy sign.
@export var longitude_deg: float = -39.561
## Body-fixed latitude (deg, -90..90); positive values move the site north.
@export var latitude_deg: float = 24.806
## Entrance heading around the local vertical (deg); changing it rotates the cave footprint.
@export var heading_deg: float = 0.0
## Deterministic geometry and dressing seed; changing it produces a different cave.
@export var seed: int = 104729
## Authored dimensions, openings and asset library for this site.
@export var profile: CaveProfile
## Entrance elevation above the reference planet radius (m), pinned during terrain fitting.
@export var surface_height_m: float = 0.0
## Planet radius at fitting time (m); a different target radius requires refitting.
@export var planet_radius_m: float = 6356000.0
## Terrain data version used for fitting; a mismatch rejects the site until it is refitted.
@export var terrain_version: String = ""
## Native relief signature at fitting time; changes to carving or terrain modifiers require refitting the site.
@export var terrain_relief_signature: String = ""
## Maximum entrance approach length (m, 20..1600); higher values allow a longer terrain connection.
@export var ramp_length_m: float = 55.0
## Minimum rock cover (m, at least 1); higher values bury the network farther below the surface.
@export var cover_m: float = 2.0
## Placement coordinate format (1 legacy, 2 native); use the migration function instead of changing it by hand.
@export var format_version: int = 1
## Optional fitted depth, pinned in the authored placement after exact terrain validation.
@export var fitted_mouth_depth_m: float = -1.0
@export_group("Version 8 entrance")
## Where the network starts relative to the entrance point, in the site frame (m): x lateral, z along the
## heading. Pinned when the entrance is fitted to the relief, like the depth, so cuts never query terrain.
@export var network_offset: Vector3 = Vector3.ZERO
## Porch descent below horizontal (deg): 0 bores straight into a cliff, up to 24 dives into flat ground.
@export var portal_descent_deg: float = 0.0
## Straight porch length (m) from the mouth until the whole mouth outline lies under the relief.
@export var portal_axis_m: float = 0.0
## Doline: depth (m) below the entrance point where the network's open throat meets the funnel walls.
@export var skylight_depth_m: float = 0.0
@export_group("Version 9 light shafts")
## Light shafts pinned at the fit, in the site frame: x and z of each shaft's axis, the radius (m) of its hole in
## the ground, and the depth (m) below the entrance point where the network's open pipe meets the walls built up
## to the ground (negative above it, for a porch bored into a cliff).
@export var light_wells: PackedVector4Array = PackedVector4Array()


func validation_error(data: PlanetData) -> String:
    var error := definition_error()
    if not error.is_empty():
        return error
    if planet_name != data.planet_name or absf(data.radius - planet_radius_m) > 0.01:
        return "Le corps ou son rayon a changé : replacer la grotte."
    if terrain_version != data.chunk_data_version:
        return "La version du terrain a changé : replacer la grotte."
    if terrain_relief_signature != data.relief_signature:
        return "Le relief natif a changé : recaler la grotte (Peupler → Recaler)."
    if fitted_mouth_depth_m < 0.0 or (profile.entrance_type != "shaft" and portal_axis_m <= 0.0):
        return "Entrée non ajustée au relief : recaler la grotte (Peupler → Recaler)."
    return ""


## Structural validation also protects saved settings before any planet loads.
func definition_error() -> String:
    if format_version not in [1, 2] or placement_id.is_empty() or profile == null:
        return "Placement incomplet ou version inconnue."
    for value in [longitude_deg, latitude_deg, heading_deg, surface_height_m,
            planet_radius_m, ramp_length_m, cover_m, fitted_mouth_depth_m,
            network_offset.x, network_offset.y, network_offset.z, portal_descent_deg, portal_axis_m, skylight_depth_m]:
        if not is_finite(value):
            return "Coordonnée non finie."
    if network_offset.length() > 2000.0 or portal_descent_deg < 0.0 or portal_descent_deg > CavePortal.MAX_DESCENT_DEG \
            or portal_axis_m < 0.0 or portal_axis_m > 300.0 or skylight_depth_m < 0.0 or skylight_depth_m > 1000.0:
        return "Ajustement de l’entrée hors limites."
    if light_wells.size() > CaveLayoutV8.MAX_LIGHT_SHAFTS:
        return "Trop de puits de lumière."
    for well in light_wells:
        if not (is_finite(well.x) and is_finite(well.y) and is_finite(well.z) and is_finite(well.w)) \
                or Vector2(well.x, well.y).length() > 3000.0 or well.z < 0.5 or well.z > 20.0 or absf(well.w) > 1000.0:
            return "Ajustement d’un puits de lumière hors limites."
    if absf(latitude_deg) > 90.0 or absf(longitude_deg) > 180.0:
        return "Longitude ou latitude hors limites."
    if planet_name.is_empty() or terrain_version.is_empty() or planet_radius_m <= 0.0:
        return "Le corps, son rayon et la version du terrain sont requis."
    if cover_m < 1.0 or ramp_length_m < 20.0 or ramp_length_m > 1600.0:
        return "Dimensions du raccord invalides."
    # A porch may start its network at the mouth's own level (a gallery straight into a cliff).
    if fitted_mouth_depth_m != -1.0 and (fitted_mouth_depth_m < 0.0 or fitted_mouth_depth_m > 1000.0):
        return "Profondeur du raccord au relief invalide."
    if profile.asset_library:
        var library_error := profile.asset_library.validation_error()
        if not library_error.is_empty():
            return library_error
    return CaveGenerator.validation_error(profile.snapshot(seed))


func mouth_depth() -> float:
    if fitted_mouth_depth_m >= 0.0:
        return fitted_mouth_depth_m
    # Before the fit: deep enough for the tallest authored room under the cover.
    return maxf(profile.chamber_height_m, maxf(profile.tunnel_height_m, profile.entrance_height_m)) + cover_m


## Version 1 used the old positive-Z longitude convention. Keep that default so
## resources that omitted it retain their physical position.
func geographic_lonlat() -> Vector2:
    return Vector2(-longitude_deg if format_version == 1 else longitude_deg, latitude_deg)


func surface_direction() -> Vector3:
    return CaveTerrain.lonlat_to_dir(geographic_lonlat())


func migrate_coordinates() -> void:
    if format_version == 1:
        longitude_deg = -longitude_deg
        format_version = 2


func surface_transform() -> Transform3D:
    var up := surface_direction()
    var reference := Vector3.UP if absf(up.y) < 0.95 else Vector3.RIGHT
    var east := reference.cross(up).normalized()
    var north := east.cross(up).normalized()
    var basis := Basis(east, up, north) * Basis(Vector3.UP, deg_to_rad(heading_deg))
    return Transform3D(basis, up * (planet_radius_m + surface_height_m))


func cave_transform() -> Transform3D:
    return surface_transform() * Transform3D(Basis.IDENTITY, network_origin())


## Network origin in the site frame: the fitted depth below the entrance point, plus the version 8 offset.
func network_origin() -> Vector3:
    return network_offset + Vector3.DOWN * mouth_depth()


func signature() -> String:
    var authored := ["sealed-portals-20261019", format_version, placement_id, planet_name, longitude_deg,
        latitude_deg, heading_deg, seed, surface_height_m, planet_radius_m,
        terrain_version, ramp_length_m, cover_m,
        profile.snapshot(seed) if profile else {}]
    if fitted_mouth_depth_m >= 0.0:
        authored.append(fitted_mouth_depth_m)
    if network_offset != Vector3.ZERO or portal_axis_m > 0.0 or skylight_depth_m > 0.0:
        authored.append([network_offset, portal_descent_deg, portal_axis_m, skylight_depth_m])
    if not light_wells.is_empty():
        authored.append(light_wells)
    if not terrain_relief_signature.is_empty():
        authored.append(terrain_relief_signature)
    return str(authored).sha256_text().substr(0, 16)


## Pins an entrance fit (CavePortal.fit) in this placement.
func apply_fit(fit: Dictionary) -> void:
    network_offset = fit.offset
    portal_descent_deg = fit.descent
    portal_axis_m = fit.axis
    skylight_depth_m = fit.sky_depth
    fitted_mouth_depth_m = fit.depth
    light_wells = fit.get("lights", PackedVector4Array())
    terrain_relief_signature = fit.get("relief_signature", "")


## Conservative spatial separation for authored trial sites, including both approaches.
func footprint_bounds() -> AABB:
    var network := CaveNetwork.layout(profile.snapshot(seed))
    var bounds: AABB = cave_transform() * (network.footprint as AABB)
    for opening: Dictionary in openings():
        bounds = bounds.merge((opening.frame as Transform3D) * _opening_box(opening))
        if opening.kind == "porch":
            var bend := CavePortal.porch_bend(self)
            var reach := maxf(profile.entrance_width_m, profile.entrance_height_m) + 2.0
            var low: Vector3 = (bend.start as Vector3).min(bend.end) - Vector3.ONE * reach
            bounds = bounds.merge(surface_transform() * AABB(low, (bend.start as Vector3).max(bend.end) + Vector3.ONE * reach - low))
    return bounds


## An opening's box in its own frame: from its floor (below or, for a light shaft under a cliff, above the frame
## plane) to 10 m above that plane.
static func _opening_box(opening: Dictionary) -> AABB:
    var floor_y := -float(opening.floor_depth)
    return AABB(Vector3(-float(opening.width) * 0.5, minf(floor_y, 0.0), -float(opening.length)),
        Vector3(float(opening.width), absf(floor_y) + 10.0, float(opening.length) + float(opening.get("back", 0.0))))


## The openings cut in the terrain: a porch bored along the heading, or a doline oculus centred on the entrance
## point; the light shafts' holes; and an authored exit at the network's far end, which the offset moves with
## the network. Each is a convex outline (or convex parts of an eroded one) clipped along its own frame.
func openings() -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    var frame := surface_transform()
    var spec := profile.snapshot(seed)
    if str(spec.entrance_type) == "shaft":
        var rim := CavePortal.oculus(spec)
        var bounds := Rect2(rim[0], Vector2.ZERO)
        for point in rim:
            bounds = bounds.expand(point)
        result.append({"kind": "skylight", "frame": frame, "polygon": rim,
            "width": maxf(absf(bounds.position.x), absf(bounds.end.x)) * 2.0,
            "length": -bounds.position.y, "back": bounds.end.y, "floor_depth": skylight_depth_m, "primary": true})
        if CavePortal.erosion_amount(spec) > 0.0:
            result.back().parts = CavePortal.convex_parts(rim)  # an eroded rim is concave
    else:
        var arch := CavePortal.porch_arch(spec)
        var top := 0.0
        var side := 0.0
        for point in arch:
            top = maxf(top, point.y)
            side = maxf(side, absf(point.x))
        # Prism along the cut frame's Y: from the mouth plane to past the straight part. Never in front of the
        # mouth (that would hole the ground the player walks in on), never the hill beyond. A version 9 porch
        # opens at the back of its approach (a hollow or a notch): its prism starts at the cliff.
        var approach := CaveApproach.applies(spec, portal_descent_deg, portal_axis_m)
        var hollow := CaveApproach.shape(spec, portal_descent_deg, portal_axis_m) if approach else {}
        result.append({"kind": "porch", "frame": CavePortal.porch_frame(frame, portal_descent_deg), "polygon": arch,
            "arch": arch, "axis": Vector2(-portal_axis_m - 2.0, -float(hollow.get("start", 0.0))), "width": side * 2.0,
            "length": 0.0, "back": top, "floor_depth": portal_axis_m + 2.0, "primary": true, "approach": approach})
        if CavePortal.erosion_amount(spec) > 0.0:
            result.back().parts = CavePortal.convex_parts(arch)  # an eroded mouth is concave
        if approach:
            var outline: PackedVector2Array = hollow.outline
            var extent := Rect2(outline[0], Vector2.ZERO)
            for point in outline:
                extent = extent.expand(point)
            result.append({"kind": "approach", "frame": frame, "polygon": outline, "parts": hollow.parts,
                "width": maxf(absf(extent.position.x), absf(extent.end.x)) * 2.0, "length": maxf(0.0, -extent.position.y),
                "back": extent.end.y, "floor_depth": hollow.floor_depth, "primary": false})
    for index in light_wells.size():
        # Version 9 light shaft: a small hole around its axis, cut down to the network's top plane.
        var well := light_wells[index]
        var rim := CavePortal.light_rim(spec, index, well.z)
        var extent := Rect2(rim[0], Vector2.ZERO)
        for point in rim:
            extent = extent.expand(point)
        result.append({"kind": "light", "light": index, "center": Vector2(well.x, well.y),
            "frame": frame * Transform3D(Basis.IDENTITY, Vector3(well.x, 0.0, well.y)), "polygon": rim,
            "parts": CavePortal.convex_parts(rim), "width": maxf(absf(extent.position.x), absf(extent.end.x)) * 2.0,
            "length": -extent.position.y, "back": extent.end.y, "floor_depth": well.w, "primary": false})
    if profile.exit_open:
        var shifted := frame * Transform3D(Basis.IDENTITY, Vector3(network_offset.x, 0.0, network_offset.z))
        var exit_frame := shifted * Transform3D(Basis(Vector3.UP, PI), Vector3(0, 0, profile.length_m))
        var polygon := CaveNaturalOpening.outline(spec)
        var extent := Rect2(polygon[0], Vector2.ZERO)
        for point in polygon:
            extent = extent.expand(point)
        result.append({"kind": "exit", "frame": exit_frame, "polygon": polygon,
            "width": maxf(absf(extent.position.x), absf(extent.end.x)) * 2.0, "length": -extent.position.y,
            "back": extent.end.y, "floor_depth": mouth_depth() + profile.depth_m, "primary": false})
    return result
