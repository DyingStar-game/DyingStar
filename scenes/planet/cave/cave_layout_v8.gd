class_name CaveLayoutV8
extends RefCounted
## Version 8 network: seeded chamber archetypes spread on a 3D graph, from niches to cathedrals, linked by
## galleries, shafts, perched windows and pits. The walkable share is steered towards the profile's target.
## Version 9 adds six chamber families, seeded gallery erosion and natural light shafts; version 8 caves keep
## their exact geometry. Descriptions only: CaveNetworkMesher owns surfaces, collisions, presence and the
## measured walkable share.

## Chamber families: cathedral hall, small niche, tall narrow rift, low bedding plane, collapse chamber with a
## chaotic floor, vertical chimney, and a multi-lobed room.
const ARCHETYPES := ["hall", "alcove", "rift", "flat", "breakdown", "chimney", "lobed"]
## Version 9 families, the version 8 ones first: a dome taller than wide, a long trunk hall, a terraced room
## (flat shelves stepping down a slope), a forest of columns, a basin room (a bowl sunk in its floor) and a
## balcony room (a ledge perched in its wall).
const ARCHETYPES_V9 := ["hall", "alcove", "rift", "flat", "breakdown", "chimney", "lobed",
    "dome", "gallery", "terraced", "forest", "basin", "balcony"]
const NAMES := {"hall": "Cathédrale", "alcove": "Niche", "rift": "Faille", "flat": "Salle basse",
    "breakdown": "Effondrement", "chimney": "Cheminée", "lobed": "Salle à lobes", "doline": "Salle de doline",
    "dome": "Dôme", "gallery": "Grande galerie", "terraced": "Salle en gradins", "forest": "Forêt de colonnes",
    "basin": "Salle à vasque", "balcony": "Salle à balcon"}
## Chamber families by size class (weights over ARCHETYPES): niches, chimneys and fissures stay small,
## cathedrals and collapse halls only come large.
const SIZE_WEIGHTS := {
    "small": [0.0, 1.4, 0.9, 0.5, 0.2, 0.8, 0.2],
    "medium": [0.2, 0.3, 0.6, 0.8, 0.9, 0.3, 1.0],
    "large": [1.2, 0.0, 0.2, 0.4, 1.0, 0.0, 0.8],
}
## Version 9 weights over ARCHETYPES_V9: the new families mostly come medium or large.
const SIZE_WEIGHTS_V9 := {
    "small": [0.0, 1.4, 0.9, 0.5, 0.2, 0.8, 0.2, 0.3, 0.0, 0.0, 0.0, 0.25, 0.0],
    "medium": [0.2, 0.3, 0.6, 0.8, 0.9, 0.3, 1.0, 0.6, 0.6, 0.5, 0.5, 0.6, 0.4],
    "large": [1.2, 0.0, 0.2, 0.4, 1.0, 0.0, 0.8, 0.5, 0.7, 0.6, 0.6, 0.5, 0.7],
}
## Version 9 gallery erosion (CaveNetworkMesher mirrors these): the section's half-width varies by up to this
## share, its centre drifts sideways by up to this share of the half-width, the roof rises or sinks by
## RISE × height (at most RISE_MAX_M) and dissolution bells lift it by up to BELL × height (BELL_MAX_M).
const ERODE_WIDEN := 0.35
const ERODE_SHIFT := 0.2
const ERODE_RISE := 0.3
const ERODE_RISE_MAX_M := 3.0
const ERODE_BELL := 0.6
const ERODE_BELL_MAX_M := 4.0
## Distance (m) over which the entrance gallery's erosion fades in, so the vestibule joins a clean section.
const ERODE_RAMP_M := 9.0
const MAX_LIGHT_SHAFTS := 4
## Version 9 chambers that never host a rock bridge: its span would cross terraces, columns or a basin.
const NO_BRIDGE := ["terraced", "forest", "basin"]
## Version 9: share of the long walkable galleries crossing a pit they can still be walked past, and odds that
## a gallery no window can bar gets a pit across it instead.
const PASSABLE_PIT_ODDS := 0.1
const BARRING_PIT_ODDS := 0.3
## Cave patterns after Palmer (1991, "Origin and morphology of limestone caves"). Each one sets how many
## chambers, their size distribution (log-normal median and spread as a share of the authored chamber size, with
## a chance of a giant), how passages branch (chain = continue from the last chamber, hub = grow from the
## largest), loops, passage lengths, turns, a joint grid, vertical behaviour, passage sections and family bias.
const STYLES := {
    "branchwork": {"name": "Réseau ramifié", "rooms": 1.0, "median": 0.3, "sigma": 0.8, "giant": 0.12, "landmark": 0.6,
        "chain": 0.65, "hub": 0.0, "loops": 0.08, "gap": Vector2(14.0, 70.0), "turn": 0.7, "grid": false,
        "vertical": "tiers", "dead_ends": 0.3, "trunk": true,
        "sections": {"tube": 0.4, "canyon": 0.3, "keyhole": 0.2, "low": 0.1},
        "bias": {"breakdown": 1.4, "hall": 1.2, "gallery": 2.0, "terraced": 1.3}},
    "maze": {"name": "Labyrinthe de fissures", "rooms": 1.3, "median": 0.12, "sigma": 0.5, "giant": 0.0, "landmark": 0.05,
        "chain": 0.35, "hub": 0.0, "loops": 0.55, "gap": Vector2(8.0, 26.0), "turn": 0.2, "grid": true,
        "vertical": "flat", "dead_ends": 0.25, "trunk": false,
        "sections": {"tube": 0.1, "canyon": 0.75, "keyhole": 0.1, "low": 0.05},
        "bias": {"rift": 3.0, "alcove": 1.5}},
    "anastomotic": {"name": "Réseau anastomosé", "rooms": 1.1, "median": 0.22, "sigma": 0.6, "giant": 0.04, "landmark": 0.2,
        "chain": 0.5, "hub": 0.0, "loops": 0.5, "gap": Vector2(10.0, 40.0), "turn": 1.1, "grid": false,
        "vertical": "flat", "dead_ends": 0.15, "trunk": false,
        "sections": {"tube": 0.35, "canyon": 0.0, "keyhole": 0.0, "low": 0.65},
        "bias": {"flat": 3.0, "lobed": 1.3, "basin": 1.6, "forest": 1.3}},
    "spongework": {"name": "Réseau en éponge", "rooms": 1.8, "median": 0.18, "sigma": 0.9, "giant": 0.06, "landmark": 0.3,
        "chain": 0.3, "hub": 0.2, "loops": 0.45, "gap": Vector2(3.0, 14.0), "turn": 1.6, "grid": false,
        "vertical": "drift", "dead_ends": 0.2, "trunk": false,
        "sections": {"tube": 0.6, "canyon": 0.1, "keyhole": 0.0, "low": 0.3},
        "bias": {"lobed": 1.6, "alcove": 1.4, "dome": 1.5}},
    "ramiform": {"name": "Réseau ramiforme", "rooms": 1.0, "median": 0.45, "sigma": 0.85, "giant": 0.35, "landmark": 0.9,
        "chain": 0.2, "hub": 0.6, "loops": 0.12, "gap": Vector2(6.0, 30.0), "turn": 1.3, "grid": false,
        "vertical": "tiers", "dead_ends": 0.6, "trunk": false,
        "sections": {"tube": 0.55, "canyon": 0.2, "keyhole": 0.05, "low": 0.2},
        "bias": {"hall": 1.6, "lobed": 1.5, "breakdown": 1.3, "dome": 1.5, "balcony": 1.6, "forest": 1.2}},
    "shafts": {"name": "Gouffres en cascade", "rooms": 0.9, "median": 0.22, "sigma": 0.6, "giant": 0.08, "landmark": 0.4,
        "chain": 0.85, "hub": 0.0, "loops": 0.05, "gap": Vector2(6.0, 24.0), "turn": 0.9, "grid": false,
        "vertical": "cascade", "dead_ends": 0.2, "trunk": false,
        "sections": {"tube": 0.3, "canyon": 0.6, "keyhole": 0.1, "low": 0.0},
        "bias": {"chimney": 3.0, "rift": 1.5, "dome": 1.8}},
}
## Draw weights of the patterns when the profile leaves the choice to the seed: branchwork caves dominate in
## nature, mazes and cascades of shafts are rarer.
const STYLE_ODDS := {"branchwork": 0.34, "ramiform": 0.2, "spongework": 0.14, "anastomotic": 0.12,
    "maze": 0.1, "shafts": 0.1}
## Allocated lattice samples (16³ blocks touched by the supports). Beyond it the cell grows: a giant network
## then meshes coarser instead of producing a million triangles for the game to stream and collide.
const MAX_SAMPLES := 3000000
const MAX_CELL_M := 3.5
## Version 9: fillet (in cells) where volumes meet, and the thinnest column (in cells): a column a cell or two
## wide meshed as a square prism with knife edges.
const BLEND_CELLS := 1.0
const COLUMN_MIN_CELLS := 1.6
const MAX_ROOMS := 24
## tan(35°): a steeper gallery is an obstacle (shaft or climb) unless rebuilt as a spiral ramp.
const WALK_SLOPE := 0.7
## tan(25°): the grade of spiral ramps.
const SPIRAL_SLOPE := 0.466
## Solid rock kept between two chambers.
const ROCK_GAP_M := 5.0
## Mesher noise peak: relief may reach amplitude × this.
const NOISE_PEAK := 1.6


static func validation_error(spec: Dictionary) -> String:
    for key in ["branches", "pillars", "bridges", "crawls", "levels"]:
        if typeof(spec.get(key)) != TYPE_INT:
            return "Paramètre entier attendu : " + key
    if int(spec.branches) < 0 or int(spec.branches) > 8 or int(spec.pillars) < 0 or int(spec.pillars) > 12:
        return "Réseau : 0–8 branches et 0–12 piliers."
    if int(spec.bridges) < 0 or int(spec.bridges) > 3 or int(spec.crawls) < 0 or int(spec.crawls) > 4:
        return "Formations : 0–3 ponts rocheux et 0–4 passages bas."
    if int(spec.levels) < 1 or int(spec.levels) > 4:
        return "Le nombre de niveaux doit être compris entre 1 et 4."
    var target: Variant = spec.get("walkable_target")
    if typeof(target) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(target)) \
            or float(target) < 0.2 or float(target) > 0.95:
        return "La part traversable visée doit être comprise entre 20 et 95 %."
    var style := str(spec.get("network_style", "auto"))
    if style != "auto" and not STYLES.has(style):
        return "Type de réseau inconnu."
    if spec.length_m < 80 or spec.length_m > 1000 or spec.width_m < 4 or spec.height_m < 3 \
            or spec.depth_m > 480:
        return "Réseau : longueur 80–1000 m, passage ≥ 4 × 3 m, dénivelé ≤ 480 m."
    if spec.length_m < spec.chamber_width_m + 40:
        return "Prévoir au moins la largeur maximale des salles plus 40 m de longueur."
    if spec.depth_m < 8.0 * (int(spec.levels) - 1):
        return "Les niveaux nécessitent au moins 8 m de dénivelé par niveau supplémentaire."
    if int(layout(spec).estimate) > MAX_SAMPLES:
        return "Réseau trop volumineux : réduire les salles, les niveaux ou la longueur."
    return ""


static func layout(spec: Dictionary) -> Dictionary:
    var rng := RandomNumberGenerator.new()
    rng.seed = int(spec.seed)
    var phase := rng.randf_range(0, TAU)
    var noise_seed := rng.randi()
    var ctx := _context(spec)
    ctx.style = _resolve_style(spec, rng)
    ctx.pattern = STYLES[ctx.style]
    ctx.grid_yaw = rng.randf_range(0.0, PI * 0.5)
    var rooms := _place_rooms(spec, ctx, rng)
    var links := _connect(spec, ctx, rooms, rng)
    var estimate := _steer(spec, rooms, links, rng)
    if ctx.v9:
        _passable_pits(links, rng)
    var pillars := _pillar_sites(spec, rooms, rng)
    # Doline throat: wider than the oculus, like a cenote. The rock lip between the ground and the chamber then
    # overhangs all around: from above only the hole shows, over the dark chamber, never a bowl around a pipe.
    ctx.throat = CavePortal.oculus_outer_radius(spec) * rng.randf_range(1.05, 1.25) if ctx.doline else 0.0
    var lights: Array[Dictionary] = []
    if ctx.v9:
        pillars.append_array(_forest_columns(spec, rooms, links, rng))
        lights = _light_sites(spec, ctx, rooms, rng)
    var cell := clampf(float(spec.width_m) / 4.0, 1.0, 1.5)
    var graph := {}
    for attempt in 16:
        graph = _emit(spec, ctx, rooms, links, pillars, cell, lights)
        if int(graph.estimate) <= MAX_SAMPLES or cell >= MAX_CELL_M:
            break
        cell = minf(MAX_CELL_M, cell * 1.1)
    graph.merge({"roughness": float(spec.roughness), "phase": phase, "noise_seed": noise_seed,
        "v8": true, "walk_estimate": estimate, "walk_target": float(spec.walkable_target), "style": ctx.style})
    if ctx.v9:
        # Version 9: volumes meet in rounded fillets (CaveNetworkMesher smooth union), about a cell wide.
        graph.blend_m = clampf(float(graph.cell_m) * BLEND_CELLS, 1.0, 2.5)
    return graph


## Version 8 may end its network with a terminal run of very low passages (CaveCrawlPassage); version 9 never
## does, whatever the profile's crawl count.
static func has_crawls(spec: Dictionary) -> bool:
    return int(spec.crawls) > 0 and int(spec.version) < 9


static func _context(spec: Dictionary) -> Dictionary:
    var crawls := has_crawls(spec)
    var levels := int(spec.levels)
    return {"entry_end": CaveNaturalOpening.REAR_Z + 2.0, "has_crawls": crawls, "v9": int(spec.version) >= 9,
        # A doline opens the first chamber's vault to the sky; every other entrance is a porch gallery.
        "doline": str(spec.entrance_type) == "shaft", "throat": 0.0,
        "network_end": float(spec.length_m) - (24.0 if crawls else 0.0),
        # Same cover contract as version 6: nothing rises above the tallest authored chamber.
        "top_y": float(spec.chamber_height_m), "bottom_y": -float(spec.depth_m), "levels": levels,
        "tier_gap": float(spec.depth_m) / (levels - 1) if levels > 1 else 0.0,
        "x_limit": maxf(40.0, maxf(float(spec.length_m) * 0.45, float(spec.chamber_width_m) * 0.8))}


# ---------------------------------------------------------------- chambers

## The profile's pattern, or one drawn from STYLE_ODDS when it leaves the choice to the seed ("auto").
static func _resolve_style(spec: Dictionary, rng: RandomNumberGenerator) -> String:
    var requested := str(spec.get("network_style", "auto"))
    var total := 0.0
    for key: String in STYLE_ODDS:
        total += float(STYLE_ODDS[key])
    var draw := rng.randf() * total  # drawn even when chosen, so the rest of the seed stays put
    if STYLES.has(requested):
        return requested
    for key: String in STYLE_ODDS:
        draw -= float(STYLE_ODDS[key])
        if draw <= 0.0:
            return key
    return "branchwork"


static func _place_rooms(spec: Dictionary, ctx: Dictionary, rng: RandomNumberGenerator) -> Array[Dictionary]:
    var rooms: Array[Dictionary] = []
    var drawn := int(spec.chambers) + rng.randi_range(1, 2 + int(spec.chambers) / 3)
    var count := clampi(int(round(drawn * float(ctx.pattern.rooms))), 2, MAX_ROOMS)
    ctx.count = count
    var descend := clampf((ctx.levels - 1) / maxf(1.0, count * 0.55), 0.15, 0.6)
    # Many caves are organised around one major chamber, met early along the way.
    var landmark := rng.randi_range(0, mini(count - 1, 3)) if rng.randf() < float(ctx.pattern.landmark) else -1
    for index in count:
        var room := _draw_room(spec, ctx, rng, index == landmark)
        if rooms.is_empty():
            room.size.y = maxf(room.size.y, 3.0)  # the chamber reached from the entrance stands upright
            if ctx.doline:
                room = _doline_chamber(spec, rng)
        var placed := false
        for shrink in 3:
            for attempt in 40:
                if _try_place(room, _choose_parent(rooms, rng, ctx), rooms, spec, ctx, descend, rng):
                    placed = true
                    break
            if placed:
                break
            _scale(room, 0.72)
        if placed:
            rooms.append(room)
    if rooms.is_empty():
        var fallback := _dimensions("alcove", 4.0, spec, rng)
        fallback.size.y = 3.0
        fallback.a = Vector3(0, 0, float(ctx.entry_end) + 12.0 + fallback.radius)
        fallback.parent = -1
        fallback.tier = 0
        rooms.append(fallback)
    for room in rooms:
        room.level = room.tier
    return rooms


## One chamber: a size from the pattern's log-normal (a share of the authored chamber size), now and then a
## giant whatever the authored size, then a family that suits that size and the pattern. The landmark is the
## cave's main chamber, at the authored size.
static func _draw_room(spec: Dictionary, ctx: Dictionary, rng: RandomNumberGenerator, landmark: bool = false) -> Dictionary:
    var pattern: Dictionary = ctx.pattern
    var scale := float(spec.chamber_width_m) * 0.5
    var reach := clampf(scale * float(pattern.median) * exp(rng.randfn(0.0, float(pattern.sigma))), 2.5, scale)
    if landmark:
        reach = maxf(reach, scale * rng.randf_range(0.7, 1.0))
    if rng.randf() < float(pattern.giant):
        reach = minf(160.0, maxf(scale * rng.randf_range(1.2, 2.0), rng.randf_range(25.0, 60.0)))
    var size_class := "small" if reach < scale * 0.22 else ("large" if reach >= scale * 0.7 or reach >= 30.0 else "medium")
    if ctx.v9:
        return _dimensions(_pick(SIZE_WEIGHTS_V9[size_class], pattern.bias, rng, ARCHETYPES_V9), reach, spec, rng)
    return _dimensions(_pick(SIZE_WEIGHTS[size_class], pattern.bias, rng), reach, spec, rng)


## The bell chamber under a doline: wide enough that the throat opens well inside its vault, level floor.
static func _doline_chamber(spec: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
    var reach := float(spec.entrance_width_m) * 0.5
    var room := _dimensions("hall", maxf(float(spec.chamber_width_m) * 0.4, reach * 1.7), spec, rng)
    room.archetype = "doline"
    room.tilt = Vector2.ZERO
    room.k = rng.randf_range(1.6, 2.2)
    room.size = Vector3(maxf(room.size.x, reach * 1.7), maxf(room.size.y, maxf(10.0, reach * 0.9)),
        maxf(room.size.z, reach * 1.7))
    _finish(room, float(spec.roughness))
    return room


static func _pick(weights: Array, bias: Dictionary, rng: RandomNumberGenerator, archetypes: Array = ARCHETYPES) -> String:
    var values: Array[float] = []
    var total := 0.0
    for index in archetypes.size():
        values.append(float(weights[index]) * float(bias.get(archetypes[index], 1.0)))
        total += values.back()
    var draw := rng.randf() * total
    for index in values.size():
        draw -= values[index]
        if draw <= 0.0 and values[index] > 0.0:
            return archetypes[index]
    return "alcove"


## Proportions of each family around [param reach], the chamber's main horizontal half-extent (m).
static func _dimensions(archetype: String, reach: float, spec: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
    var cap_h := float(spec.chamber_height_m)
    var rough := float(spec.roughness)
    var room := {"kind": "room", "archetype": archetype, "yaw": rng.randf_range(0, TAU), "e": 2.0, "k": 2.0,
        "tilt": Vector2.ZERO, "floor_rough": rough * 0.5, "lobes": [], "terrace": 0.0, "basin": 0.0, "basin_r": 0.0}
    var size := Vector3.ONE
    match archetype:
        "hall":
            size.x = reach
            size.z = maxf(6.0, reach * rng.randf_range(0.55, 1.4))
            size.y = clampf(reach * rng.randf_range(0.35, 0.75), 6.0, maxf(cap_h * 1.6, 8.0))
            room.e = rng.randf_range(1.8, 2.6)
            room.k = rng.randf_range(1.5, 2.6)
            room.tilt = Vector2(rng.randf_range(-0.06, 0.06), rng.randf_range(-0.06, 0.06))
            room.floor_rough = rough * clampf(reach * 0.03, 0.5, 4.0)
        "alcove":
            size.x = clampf(reach, 2.5, 7.0)
            size.z = size.x * rng.randf_range(0.7, 1.4)
            size.y = clampf(size.x * rng.randf_range(0.6, 1.2), 2.4, 6.0)
            room.k = rng.randf_range(1.5, 3.0)
        "rift":
            size.x = rng.randf_range(1.8, 4.5)
            size.z = maxf(8.0, reach * rng.randf_range(0.8, 1.6))
            size.y = clampf(reach * rng.randf_range(0.8, 1.8), 6.0, maxf(cap_h * 1.5, 10.0))
            room.e = rng.randf_range(2.5, 4.0)
            room.k = rng.randf_range(3.0, 6.0)
        "flat":
            size.x = maxf(5.0, reach)
            size.z = maxf(5.0, reach * rng.randf_range(0.6, 1.5))
            size.y = rng.randf_range(1.5, 3.6)  # sometimes only crawlable
            room.e = rng.randf_range(2.0, 3.2)
            room.k = rng.randf_range(3.0, 6.0)
            room.tilt = Vector2(rng.randf_range(-0.04, 0.04), rng.randf_range(-0.04, 0.04))
            room.floor_rough = rough * 0.3
        "breakdown":
            size.x = maxf(5.0, reach)
            size.z = maxf(5.0, reach * rng.randf_range(0.6, 1.4))
            size.y = clampf(reach * rng.randf_range(0.4, 0.8), 5.0, maxf(cap_h * 1.4, 8.0))
            room.e = rng.randf_range(1.6, 2.2)
            room.k = rng.randf_range(1.2, 2.0)
            room.tilt = Vector2(rng.randf_range(-0.3, 0.3), rng.randf_range(-0.3, 0.3))
            room.floor_rough = clampf(minf(size.x, size.z) * rng.randf_range(0.04, 0.08), 0.8, 4.0)
        "chimney":
            size.x = clampf(reach * 0.5, 2.5, 7.0)
            size.z = size.x * rng.randf_range(0.8, 1.25)
            size.y = clampf(reach * rng.randf_range(1.5, 3.0), 12.0, maxf(cap_h * 2.0, 16.0))
            room.k = rng.randf_range(4.0, 8.0)
        "lobed":
            size.x = maxf(5.0, reach * 0.75)
            size.z = maxf(5.0, size.x * rng.randf_range(0.6, 1.3))
            size.y = clampf(reach * rng.randf_range(0.3, 0.6), 4.0, maxf(cap_h * 1.2, 6.0))
            for index in rng.randi_range(2, 3):
                var angle := rng.randf_range(0, TAU)
                # Lobe floors stay within a walkable step of the main floor: deeper ones cut ledges under doorways.
                var step := clampf(rng.randf_range(-0.04, 0.05) * size.y, -1.2, 1.2)
                room.lobes.append({"offset": Vector3(cos(angle) * size.x * 0.8, step, sin(angle) * size.z * 0.8),
                    "size": Vector3(size.x * rng.randf_range(0.35, 0.7), size.y * rng.randf_range(0.5, 0.9),
                        size.z * rng.randf_range(0.35, 0.7)), "k": rng.randf_range(1.6, 3.0)})
        "dome":
            # A rotunda dissolved upwards: round footprint, a cupola taller than the room is wide.
            size.x = clampf(reach * 0.75, 4.0, minf(60.0, maxf(cap_h * 1.4, 6.0)))  # room left to rise above it
            size.z = size.x * rng.randf_range(0.85, 1.15)
            size.y = clampf(size.x * rng.randf_range(1.1, 2.2), 6.0, maxf(cap_h * 1.8, 10.0))
            room.k = rng.randf_range(1.4, 2.0)
            room.floor_rough = rough * 0.4
        "gallery":
            # A trunk passage widened into a hall: long, straight, boxy, gently graded along its length.
            size.z = maxf(10.0, reach)
            size.x = clampf(reach * rng.randf_range(0.14, 0.28), 3.5, 24.0)
            size.y = clampf(size.x * rng.randf_range(0.9, 1.8), 4.0, maxf(cap_h * 1.3, 8.0))
            room.e = rng.randf_range(2.6, 4.0)
            room.k = rng.randf_range(2.2, 3.5)
            room.tilt = Vector2(0.0, rng.randf_range(-0.08, 0.08))
            room.floor_rough = rough * 0.6
        "terraced":
            # Flat shelves stepping down a slope (rimstone or bedding ledges); the rim stays a continuous ramp.
            size.x = maxf(6.0, reach)
            size.z = maxf(6.0, reach * rng.randf_range(0.7, 1.3))
            size.y = clampf(reach * rng.randf_range(0.35, 0.7), 5.0, maxf(cap_h * 1.3, 8.0))
            room.e = rng.randf_range(1.8, 2.4)
            room.k = rng.randf_range(1.8, 2.6)
            var grade := rng.randf_range(0.14, 0.3)
            var heading := rng.randf_range(0, TAU)
            room.tilt = Vector2(cos(heading), sin(heading)) * grade
            room.terrace = clampf(minf(size.x, size.z) * grade * rng.randf_range(0.3, 0.5), 0.8, 3.0)
            room.floor_rough = rough * 0.25
        "forest":
            # A wide, low room whose flat roof stands on columns (_forest_columns).
            size.x = maxf(7.0, reach)
            size.z = maxf(7.0, reach * rng.randf_range(0.7, 1.3))
            size.y = clampf(reach * rng.randf_range(0.15, 0.32), 4.0, maxf(cap_h * 0.9, 6.0))
            room.e = rng.randf_range(2.2, 3.0)
            room.k = rng.randf_range(3.0, 5.0)
            room.floor_rough = rough * 0.4
        "basin":
            # A bowl sunk in the middle of the floor, gentle enough to walk down: room for a future lake.
            size.x = maxf(5.0, reach)
            size.z = maxf(5.0, reach * rng.randf_range(0.7, 1.3))
            size.y = clampf(reach * rng.randf_range(0.3, 0.6), 4.0, maxf(cap_h * 1.2, 7.0))
            room.e = rng.randf_range(1.8, 2.4)
            room.k = rng.randf_range(1.6, 2.4)
            # Steepest bowl slope ≈ 1.54 × depth / (basin_r × size): at most ~0.68, below the walking limit.
            room.basin = clampf(minf(size.x, size.z) * rng.randf_range(0.12, 0.22), 1.5, 7.0)
            room.basin_r = rng.randf_range(0.5, 0.68)
            room.floor_rough = rough * 0.3
        "balcony":
            # A tall room with a ledge perched in its wall: half of a raised lobe, outside the main footprint.
            size.x = maxf(6.0, reach * 0.85)
            size.z = maxf(6.0, size.x * rng.randf_range(0.7, 1.3))
            size.y = clampf(reach * rng.randf_range(0.5, 0.9), 9.0, maxf(cap_h * 1.5, 12.0))
            room.e = rng.randf_range(1.8, 2.4)
            room.k = rng.randf_range(1.8, 2.6)
            var angle := rng.randf_range(0, TAU)
            var lift := clampf(size.y * rng.randf_range(0.3, 0.5), 3.5, 9.0)
            room.lobes.append({"offset": Vector3(cos(angle) * size.x * 0.9, lift, sin(angle) * size.z * 0.9),
                "size": Vector3(size.x * rng.randf_range(0.3, 0.45), size.y * rng.randf_range(0.35, 0.55),
                    size.z * rng.randf_range(0.3, 0.45)), "k": rng.randf_range(2.0, 3.0), "ledge": true})
    size.y = clampf(size.y, 1.5, 200.0)
    room.size = size
    _finish(room, rough)
    return room


## Derived values that follow the size: wall relief, its frequency and the horizontal reach.
static func _finish(room: Dictionary, rough: float) -> void:
    var size: Vector3 = room.size
    room.amp = rough * clampf(minf(minf(size.x, size.z), size.y) * 0.2, 0.3, 6.0)
    room.freq = 1.0 / clampf(minf(size.x, size.z) * 0.5, 2.5, 30.0)
    var reach := Vector2(size.x, size.z).length()
    for lobe: Dictionary in room.lobes:
        var offset: Vector3 = lobe.offset
        reach = maxf(reach, Vector2(offset.x, offset.z).length() + Vector2(lobe.size.x, lobe.size.z).length())
    room.radius = reach + float(room.amp) * NOISE_PEAK


static func _scale(room: Dictionary, factor: float) -> void:
    room.size = Vector3(maxf(2.0, room.size.x * factor), maxf(2.0, room.size.y * factor), maxf(2.0, room.size.z * factor))
    for lobe: Dictionary in room.lobes:
        lobe.offset = lobe.offset * factor
        lobe.size = lobe.size * factor
    room.floor_rough = float(room.floor_rough) * factor
    room.terrace = float(room.terrace) * factor
    room.basin = float(room.basin) * factor
    room.amp = float(room.amp) * factor
    var reach := Vector2(room.size.x, room.size.z).length()
    for lobe: Dictionary in room.lobes:
        reach = maxf(reach, Vector2(lobe.offset.x, lobe.offset.z).length() + Vector2(lobe.size.x, lobe.size.z).length())
    room.radius = reach + float(room.amp) * NOISE_PEAK


## Vertical extent (lowest floor, highest roof) including tilt, floor relief, terraces, basin, lobes and wall
## relief.
static func _span(room: Dictionary) -> Vector2:
    var tilt: Vector2 = room.tilt
    var drop := (absf(tilt.x) + absf(tilt.y)) * float(room.radius) + float(room.floor_rough) * NOISE_PEAK \
        + float(room.terrace) + float(room.basin)
    var a: Vector3 = room.a
    var relief := float(room.amp) * NOISE_PEAK
    var low := a.y - drop
    var high := a.y + drop + float(room.size.y) + relief
    for lobe: Dictionary in room.lobes:
        low = minf(low, a.y + float(lobe.offset.y) - drop)
        high = maxf(high, a.y + float(lobe.offset.y) + float(lobe.size.y) + drop + relief)
    return Vector2(low, high)


## Which chamber the next one grows from: the last one (a chain), a large one (a hub, ramiform caves), any one,
## or now and then the entrance again.
static func _choose_parent(rooms: Array[Dictionary], rng: RandomNumberGenerator, ctx: Dictionary) -> int:
    if rooms.is_empty():
        return -1
    var pattern: Dictionary = ctx.pattern
    var draw := rng.randf()
    if draw < float(pattern.chain):
        return rooms.size() - 1
    if draw < float(pattern.chain) + float(pattern.hub):
        var total := 0.0
        for room in rooms:
            total += float(room.radius)
        var pick := rng.randf() * total
        for index in rooms.size():
            pick -= float(rooms[index].radius)
            if pick <= 0.0:
                return index
    if draw < 0.92 or rooms.size() >= 3:
        return rng.randi_range(0, rooms.size() - 1)
    return 0 if ctx.doline else -1  # a second gallery leaving the entrance (the doline chamber has none)


static func _try_place(room: Dictionary, parent: int, rooms: Array[Dictionary], spec: Dictionary, ctx: Dictionary,
        descend: float, rng: RandomNumberGenerator) -> bool:
    var pattern: Dictionary = ctx.pattern
    var origin := Vector3(0, 0, float(ctx.entry_end) + 8.0)
    var reach := 0.0
    var tier := 0
    if parent >= 0:
        origin = rooms[parent].a
        reach = float(rooms[parent].radius)
        tier = int(rooms[parent].tier)
    var bend := float(spec.bend)
    var angle := rng.randfn(0.0, 0.35 if parent < 0 else float(pattern.turn) * (0.5 + bend))
    if bool(pattern.grid) and parent >= 0:
        # Joint-guided maze: passages follow two perpendicular fracture sets.
        var quarter := PI * 0.5
        var yaw := float(ctx.grid_yaw)
        angle = yaw + round((angle - yaw) / quarter) * quarter + rng.randf_range(-0.08, 0.08)
    var direction := Vector3(sin(angle), 0, cos(angle))
    var gap: Vector2 = pattern.gap
    var distance := reach + float(room.radius) + rng.randf_range(gap.x, gap.y) * (0.6 + bend * 0.8)
    var center := origin + direction * distance
    if parent < 0:
        center.y = rng.randf_range(-1.0, 0.3) * minf(float(spec.depth_m), 4.0)
    else:
        match str(pattern.vertical):
            "flat":
                center.y = origin.y + rng.randf_range(-1.2, 0.6)  # one bedding plane
            "cascade":
                # Shaft series: each chamber a pitch below the last, down to the authored depth.
                var pitch := maxf(8.0, float(spec.depth_m) / maxf(1.0, float(ctx.count) * 0.6))
                center.y = maxf(origin.y - rng.randf_range(0.5, 1.0) * pitch, float(ctx.bottom_y))
                tier = mini(tier + 1, int(ctx.levels) - 1)
            _:
                if str(pattern.vertical) == "tiers" and int(ctx.levels) > 1:
                    if tier < int(ctx.levels) - 1 and rng.randf() < descend:
                        tier += 1
                    var jitter := float(ctx.tier_gap) * 0.25
                    center.y = -tier * float(ctx.tier_gap) + rng.randf_range(-jitter, jitter * 0.4)
                else:
                    var drift := minf(float(spec.depth_m), distance * 0.35)
                    center.y = origin.y + rng.randf_range(-drift, drift * 0.4)
    room.a = center
    var span := _span(room)
    if span.y > float(ctx.top_y):
        center.y -= span.y - float(ctx.top_y)  # tall chambers sink rather than pierce the cover
        room.a = center
        span = _span(room)
    # Tall chambers may reach below the authored drop: a cathedral simply digs deeper.
    if center.y < float(ctx.bottom_y) - maxf(1.0, float(room.size.y) * 0.5):
        return false
    var margin := 6.0 + float(room.amp) * NOISE_PEAK
    if center.z - float(room.radius) < float(ctx.entry_end) + 4.0 + margin \
            or center.z + float(room.radius) > float(ctx.network_end) - 6.0 - margin \
            or absf(center.x) + float(room.radius) > float(ctx.x_limit):
        return false
    for other in rooms:
        var apart := Vector2(center.x - other.a.x, center.z - other.a.z).length()
        if apart >= float(room.radius) + float(other.radius) + ROCK_GAP_M:
            continue
        var other_span := _span(other)
        if span.x < other_span.y + ROCK_GAP_M and other_span.x < span.y + ROCK_GAP_M:
            return false
    room.b = center
    room.parent = parent
    room.tier = tier
    return true


# ---------------------------------------------------------------- galleries and obstacles

static func _connect(spec: Dictionary, ctx: Dictionary, rooms: Array[Dictionary],
        rng: RandomNumberGenerator) -> Array[Dictionary]:
    var pattern: Dictionary = ctx.pattern
    var links: Array[Dictionary] = []
    var entry := Vector3(0, 0, float(ctx.entry_end) + 8.0)
    var used := {}  # chamber → doorway angles (version 9)
    var children: Array[int] = []
    children.resize(rooms.size())
    for room in rooms:
        if int(room.parent) >= 0:
            children[int(room.parent)] += 1
    for index in rooms.size():
        var parent := int(rooms[index].parent)
        if parent < 0 and ctx.doline:
            continue  # the doline chamber is entered from the sky
        var start := entry if parent < 0 else _door(ctx, spec, rooms, used, parent, rooms[index].a)
        var end := _door(ctx, spec, rooms, used, index, start)
        var link := _link(spec, pattern, start, end, parent, index, rng, _grade(ctx, rooms, parent, index, start, end))
        if parent < 0 and index == 0:
            link.width = float(spec.width_m)  # matches the entrance stub, never narrower than the vestibule
            link.height = float(spec.height_m)
            link.section = "tube"
            link.kind = "walk"  # the first chamber sits within a few metres of the entrance floor
        elif bool(pattern.trunk):
            # Branchwork: galleries that lead on to more chambers are the trunk, larger than the tributaries.
            var trunk := 1.25 if children[index] > 0 else 0.8
            link.width = float(link.width) * trunk
            link.height = float(link.height) * trunk
        if not (parent < 0 and index == 0):
            _fit_width(ctx, rooms, link)
        links.append(link)
    var loops := 0
    var reach := 35.0 if not bool(pattern.grid) else 25.0
    for i in rooms.size():
        for j in range(i + 1, rooms.size()):
            if loops > rooms.size() * float(pattern.loops) * 1.5 or int(rooms[j].parent) == i or int(rooms[i].parent) == j:
                continue
            var apart := Vector2(rooms[i].a.x - rooms[j].a.x, rooms[i].a.z - rooms[j].a.z).length()
            if apart < float(rooms[i].radius) + float(rooms[j].radius) + reach and rng.randf() < float(pattern.loops):
                var probe := used.duplicate(true)  # trial doorways: a loop overlapping another gallery is dropped
                var from := _door(ctx, spec, rooms, probe, i, rooms[j].a)
                var to := _door(ctx, spec, rooms, probe, j, rooms[i].a)
                var loop := _link(spec, pattern, from, to, i, j, rng, _grade(ctx, rooms, i, j, from, to))
                loop.role = "loop"
                _fit_width(ctx, rooms, loop)
                if ctx.v9 and not _clear_path(loop, links, rooms):
                    continue
                _door(ctx, spec, rooms, used, i, rooms[j].a)
                _door(ctx, spec, rooms, used, j, rooms[i].a)
                links.append(loop)
                loops += 1
    var dead_ends := mini(int(spec.branches) + int(round(float(pattern.dead_ends) * rooms.size())), 12)
    for index in dead_ends:
        # Version 9 tries a few directions for a dead end clear of every gallery already laid; version 8 one.
        for attempt in (6 if ctx.v9 else 1):
            var from := rng.randi_range(0, rooms.size() - 1)
            var center: Vector3 = rooms[from].a
            var angle := rng.randf_range(0, TAU)
            if bool(pattern.grid):
                angle = float(ctx.grid_yaw) + rng.randi_range(0, 3) * PI * 0.5
            var end := center + Vector3(sin(angle), 0, cos(angle)) * (float(rooms[from].radius) + rng.randf_range(12.0, 45.0))
            end.y += rng.randf_range(-8.0, 3.0)
            end.x = clampf(end.x, -float(ctx.x_limit) + 6.0, float(ctx.x_limit) - 6.0)
            end.z = clampf(end.z, float(ctx.entry_end) + 14.0, float(ctx.network_end) - 14.0)
            var probe := used.duplicate(true)
            var door := _door(ctx, spec, rooms, probe, from, end)
            var branch := _link(spec, pattern, door, end, from, -1, rng, _grade(ctx, rooms, from, -1, door, end))
            branch.role = "branch"
            if branch.kind not in ["walk", "crawl"]:
                branch.kind = "climb"
            _fit_width(ctx, rooms, branch)
            if ctx.v9 and not _clear_path(branch, links, rooms):
                continue
            _door(ctx, spec, rooms, used, from, end)
            links.append(branch)
            break
    return links


## Version 9: true when the optional gallery [param link] (a loop or a dead end) keeps clear of the galleries
## already laid and of the chambers it does not join, beyond its own chambers' walls. Overlapping galleries at
## different grades left a floor step where they parted, and a gallery through a chamber cut a trench in it.
static func _clear_path(link: Dictionary, links: Array[Dictionary], rooms: Array[Dictionary]) -> bool:
    var a: Vector3 = link.a
    var b: Vector3 = link.b
    # Trim the stretches inside the joined chambers: there galleries meet by design.
    var flat_a := Vector2(a.x, a.z)
    var flat_b := Vector2(b.x, b.z)
    var direction := (flat_b - flat_a).normalized()
    var length := flat_a.distance_to(flat_b)
    var start := 0.0
    var finish := length
    if int(link.from) >= 0:
        start = minf(length, float(rooms[int(link.from)].radius) * 0.4 + float(link.width) * 0.5)
    if int(link.to) >= 0:
        finish = maxf(start, length - float(rooms[int(link.to)].radius) * 0.4 - float(link.width) * 0.5)
    var from := flat_a + direction * start
    var to := flat_a + direction * finish
    var low := minf(a.y, b.y) - 3.0
    var high := maxf(a.y, b.y) + float(link.height) + 3.0
    for other in links:
        var oa: Vector3 = other.a
        var ob: Vector3 = other.b
        if minf(oa.y, ob.y) > high or maxf(oa.y, ob.y) + float(other.height) < low:
            continue
        var closest := Geometry2D.get_closest_points_between_segments(from, to, Vector2(oa.x, oa.z), Vector2(ob.x, ob.z))
        if closest[0].distance_to(closest[1]) < (float(link.width) + float(other.width)) * 0.5 + 6.0:
            return false
    for index in rooms.size():
        if index == int(link.from) or index == int(link.to):
            continue
        var room_center: Vector3 = rooms[index].a
        var span := _span(rooms[index])
        if span.x > high or span.y < low:
            continue
        var near := Geometry2D.get_closest_point_to_segment(Vector2(room_center.x, room_center.z), from, to)
        if near.distance_to(Vector2(room_center.x, room_center.z)) < float(rooms[index].radius) + float(link.width) * 0.5 + 2.0:
            return false
    return true


## Version 9: a gallery is never wider than 1.2 × the narrower diameter of the chambers it joins (a 23 m wide
## bedding passage no longer leaves a 5 m niche). Version 8 keeps its widths.
static func _fit_width(ctx: Dictionary, rooms: Array[Dictionary], link: Dictionary) -> void:
    if not ctx.v9:
        return
    var narrowest := INF
    for index: int in [int(link.from), int(link.to)]:
        if index >= 0:
            narrowest = minf(narrowest, minf(float(rooms[index].size.x), float(rooms[index].size.z)))
    if is_finite(narrowest):
        link.width = minf(float(link.width), maxf(3.0, narrowest * 2.4))


## Where a gallery meets a chamber: on its floor at 82 % of the footprint radius towards [param toward]. The
## centre stays free for chasms and pillars, and galleries arrive on the floor rim around them. With
## [param share] 1, the point where that gallery crosses the chamber's wall, on the same tilted floor plane.
static func _doorway(room: Dictionary, toward: Vector3, share: float = 0.82) -> Vector3:
    var a: Vector3 = room.a
    var direction := Vector3(toward.x - a.x, 0, toward.z - a.z)
    if direction.length() < 0.01:
        return a
    direction = direction.normalized()
    var local := Basis(Vector3.UP, float(room.yaw)).inverse() * direction
    var e := float(room.e)
    var boundary := pow(pow(absf(local.x) / float(room.size.x), e) + pow(absf(local.z) / float(room.size.z), e), -1.0 / e)
    var tilt: Vector2 = room.tilt
    var distance := boundary * share
    return a + direction * distance + Vector3.UP * (tilt.x * local.x + tilt.y * local.z) * distance


## The doorway of a new gallery on chamber [param index] towards [param toward]. Version 9 turns it around the
## chamber until it stands clear of the doorways already taken there ([param used]: chamber → angles): two
## galleries leaving one doorway side by side overlapped, and where they parted one was left perched above
## the other's floor. It turns 63° at most, so the gallery still heads out of the (convex) chamber instead
## of running back along its rim and cutting a trench across its floor.
static func _door(ctx: Dictionary, spec: Dictionary, rooms: Array[Dictionary], used: Dictionary, index: int,
        toward: Vector3) -> Vector3:
    if not ctx.v9:
        return _doorway(rooms[index], toward)
    var center: Vector3 = rooms[index].a
    var aim := atan2(toward.x - center.x, toward.z - center.z)
    var span := minf(float(rooms[index].size.x), float(rooms[index].size.z)) * 0.82
    var gap := clampf(float(spec.width_m) * 1.2 / maxf(span, 0.1), 0.4, 1.4)
    var taken: Array = used.get(index, [])
    var best := aim
    var best_clearance := -INF
    for turn: int in [0, 1, -1, 2, -2, 3, -3]:
        if absf(turn * gap) > 1.1:
            continue
        var angle := aim + turn * gap
        var clearance := INF
        for other: float in taken:
            clearance = minf(clearance, absf(angle_difference(angle, other)))
        if clearance >= gap:
            best = angle
            break
        if clearance > best_clearance:
            best = angle
            best_clearance = clearance
    taken.append(best)
    used[index] = taken
    return _doorway(rooms[index], center + Vector3(sin(best), 0.0, cos(best)) * 10.0)


## Version 9: where a gallery leaving [param doorway] crosses the wall of chamber [param index] (none for the
## entrance or a dead end). Its grade then ends outside the chamber, and inside it the gallery follows the
## chamber's floor: a gallery descending into a large chamber no longer stops on a ledge above that floor.
static func _landing(rooms: Array[Dictionary], index: int, doorway: Vector3) -> Variant:
    return _doorway(rooms[index], doorway, 1.0) if index >= 0 else null


## Version 9: the grade of a gallery between the chamber walls it crosses (see _landing), steeper than
## between its doorways. Negative in version 8: _link measures between the doorways.
static func _grade(ctx: Dictionary, rooms: Array[Dictionary], from: int, to: int, a: Vector3, b: Vector3) -> float:
    if not ctx.v9:
        return -1.0
    var start: Vector3 = _landing(rooms, from, a) if from >= 0 else a
    var finish: Vector3 = _landing(rooms, to, b) if to >= 0 else b
    return absf(finish.y - start.y) / maxf(Vector2(finish.x - start.x, finish.z - start.z).length(), 0.1)


## A gallery and its section: a phreatic tube (about as wide as high), a vadose canyon (narrow, tall), a
## keyhole (a tube perched on a canyon) or a low bedding passage, where under 1.9 m one has to crawl.
static func _link(spec: Dictionary, pattern: Dictionary, a: Vector3, b: Vector3, from: int, to: int,
        rng: RandomNumberGenerator, grade: float = -1.0) -> Dictionary:
    var horizontal := Vector2(b.x - a.x, b.z - a.z).length()
    var slope := absf(b.y - a.y) / maxf(horizontal, 0.1) if grade < 0.0 else grade
    var kind := "walk"
    if slope > WALK_SLOPE:
        kind = "shaft" if absf(b.y - a.y) >= 6.0 else "climb"
    var width_m := float(spec.width_m)
    var height_m := float(spec.height_m)
    var section := "tube"
    var draw := rng.randf()
    for key: String in pattern.sections:
        draw -= float(pattern.sections[key])
        if draw <= 0.0:
            section = key
            break
    var width := width_m * rng.randf_range(0.7, 1.4)
    var height := clampf(width * rng.randf_range(0.7, 1.1), 2.6, height_m * 1.8)
    var link := {"from": from, "to": to, "a": a, "b": b, "kind": kind, "role": "tree", "section": section}
    match section:
        "canyon":
            width = width_m * rng.randf_range(0.4, 0.65)
            height = height_m * rng.randf_range(1.6, 3.2)
        "keyhole":
            width = width_m * rng.randf_range(0.45, 0.6)
            height = height_m * rng.randf_range(1.2, 2.0)
            link.tube_width = width_m * rng.randf_range(0.9, 1.4)
            link.tube_height = link.tube_width * rng.randf_range(0.5, 0.8)
        "low":
            width = width_m * rng.randf_range(1.3, 2.4)
            height = rng.randf_range(1.5, 2.6)
            if height < 1.9 and kind == "walk":
                kind = "crawl"  # passable on all fours only: an obstacle for the walking share
    link.kind = kind
    link.width = maxf(3.0, width)
    link.height = maxf(1.5, height)
    return link


## Greedily turn galleries into obstacles (perched windows, pits) or obstacles into spiral ramps until the
## estimated walkable floor share lands near the target. The entrance gallery always stays walkable.
static func _steer(spec: Dictionary, rooms: Array[Dictionary], links: Array[Dictionary],
        rng: RandomNumberGenerator) -> float:
    # The estimate ignores the wall ledges and steep floor patches the lattice measure counts: measured
    # shares run ~0.08 below it, so steer slightly above the requested target.
    var target := minf(0.97, float(spec.walkable_target) + 0.06)
    var low := target - 0.05
    var high := target + 0.05
    var share := _estimate(rooms, links, int(spec.bridges), str(spec.entrance_type) == "shaft", int(spec.version) >= 9)
    var order: Array[int] = []
    for index in links.size():
        if links[index].role != "branch" and not (int(links[index].from) < 0 and int(links[index].to) == 0):
            order.append(index)
    _shuffle(order, rng)
    if share > high:
        # Version 9 first bars with windows and only a few pits; a share still far above the target (a low
        # target) brings the pits back. Some points above it are kept rather than pits across the way.
        var v9 := int(spec.version) >= 9
        for sparing in ([true, false] if v9 else [false]):
            if not sparing and v9 and share <= high + 0.15:
                break
            for index in order:
                if share <= high:
                    break
                if links[index].kind != "walk":
                    continue
                var saved: Dictionary = links[index].duplicate()
                if not _make_obstacle(links[index], rooms, rng, sparing):
                    continue
                var next := _estimate(rooms, links, int(spec.bridges), str(spec.entrance_type) == "shaft", v9)
                if next < low:
                    links[index] = saved
                else:
                    share = next
    elif share < low:
        for index in order:
            if share >= low:
                break
            var kind: String = links[index].kind
            if kind == "walk":
                continue
            links[index].kind = "spiral" if kind in ["shaft", "climb"] else "walk"
            if kind == "crawl":
                links[index].height = maxf(float(links[index].height), 2.6)  # the low passage opens up
            share = _estimate(rooms, links, int(spec.bridges), str(spec.entrance_type) == "shaft", int(spec.version) >= 9)
    return share


## Bars a gallery: a high window in the far chamber wall, or a pit across it when the gallery is long enough
## to keep the pit clear of both chambers. [param sparing] (version 9's first pass) keeps the barring pit for
## when no window fits, and then only now and then: the window reads as the cave's own shape, a pit across the
## way as an arbitrary trap. The steering bars another gallery instead. False when nothing bars this one.
static func _make_obstacle(link: Dictionary, rooms: Array[Dictionary], rng: RandomNumberGenerator,
        sparing: bool = false) -> bool:
    var child: Dictionary = rooms[int(link.to)]
    var room_space := float(child.size.y) - float(link.height) - 0.5
    var pit_radius := _pit_radius(link)
    var pit_fits := _pit_fits(link, pit_radius)
    if room_space >= 3.5 and (not pit_fits or sparing or rng.randf() < 0.5):
        link.kind = "perched"  # the gallery opens high in the chamber wall
        link.perch = rng.randf_range(3.0, minf(8.0, room_space))
        return true
    if pit_fits and (not sparing or rng.randf() < BARRING_PIT_ODDS):
        link.kind = "pit"  # a shaft bars the whole gallery
        link.pit_depth = rng.randf_range(8.0, 18.0)
        link.pit_radius = pit_radius
        return true
    return false


## A barring pit is wider than its gallery.
static func _pit_radius(link: Dictionary) -> float:
    return maxf(2.6, float(link.width) * 0.75)


## Long enough for a pit to stay clear of both chambers.
static func _pit_fits(link: Dictionary, radius: float) -> bool:
    var a: Vector3 = link.a
    var b: Vector3 = link.b
    return Vector2(b.x - a.x, b.z - a.z).length() >= radius * 4.0 + 8.0


## Version 9: some long walkable galleries cross a pit that does not bar them, a hole sunk against one wall
## beside a ledge (wide galleries only, so the ledge survives the erosion's narrowing) or a full pit under a
## natural rock bridge. They stay walkable links; the entrance gallery never gets one.
static func _passable_pits(links: Array[Dictionary], rng: RandomNumberGenerator) -> void:
    for link in links:
        if link.kind != "walk" or int(link.from) < 0 or int(link.to) < 0:
            continue
        if not _pit_fits(link, _pit_radius(link)) or rng.randf() >= PASSABLE_PIT_ODDS:
            continue
        var ledge := float(link.width) >= 4.0 and rng.randf() < 0.5
        link.pit_pass = "ledge" if ledge else "bridge"
        link.pit_depth = rng.randf_range(8.0, 18.0)
        link.pit_radius = float(link.width) * 0.4 if ledge else _pit_radius(link)
        link.pit_side = 1.0 if rng.randf() < 0.5 else -1.0


## Floor area reachable on foot from the entrance over walkable galleries, over the total floor area. Inside
## a reached chamber only the floor under 1.8 m of headroom counts, and a chasm under a rock bridge does not.
static func _estimate(rooms: Array[Dictionary], links: Array[Dictionary], bridges: int, doline: bool,
        v9: bool = false) -> float:
    var total := 0.0
    var areas: Array[float] = []
    var standing: Array[float] = []
    for room in rooms:
        var area := PI * float(room.size.x) * float(room.size.z)
        for lobe: Dictionary in room.lobes:
            if lobe.get("ledge", false):
                total += PI * float(lobe.size.x) * float(lobe.size.z) * 0.5  # a balcony is out of reach
            else:
                area += PI * float(lobe.size.x) * float(lobe.size.z) * 0.6
        areas.append(area)
        total += area
        # Radius fraction where the roof profile leaves 1.8 m above the floor, squared for an area.
        var k := float(room.k)
        var reach := pow(maxf(0.0, 1.0 - pow(minf(1.8 / float(room.size.y), 1.0), k)), 1.0 / k)
        # Terraces: the shelves between steep risers are only partly linked by ramps.
        standing.append(reach * reach * (0.65 if float(room.terrace) > 0.0 else 1.0))
    for host in _bridge_hosts(rooms, bridges, doline):
        standing[host] *= 0.7 if v9 else 0.55  # the chasm takes ~58 % (version 8: ~66 %) of the radius
    if total <= 0.0:
        return 0.0
    var reached := {-1: true, 0: true}  # the first chamber: reached by the entrance gallery, or the doline landing
    var changed := true
    while changed:
        changed = false
        for link in links:
            if link.kind not in ["walk", "spiral"] or int(link.to) < 0:
                continue
            var from_in := reached.has(int(link.from))
            var to_in := reached.has(int(link.to))
            if from_in != to_in:
                reached[int(link.to) if from_in else int(link.from)] = true
                changed = true
    var share := 0.0
    for index in rooms.size():
        if reached.has(index):
            share += areas[index] * standing[index]
    # Gallery floors: whole when walkable from a reached end, the near half before a pit or a high window.
    for link in links:
        if link.kind == "shaft":
            continue
        var a: Vector3 = link.a
        var b: Vector3 = link.b
        var area := Vector2(b.x - a.x, b.z - a.z).length() * 1.1 * float(link.width)
        total += area
        var near := reached.has(int(link.from)) or (int(link.to) >= 0 and reached.has(int(link.to)))
        if near and link.kind in ["walk", "spiral"]:
            share += area
        elif near and link.kind in ["pit", "perched"]:
            share += area * 0.5
    return share / total


## The chambers _add_bridges will span: the largest admissible ones, in the same order.
static func _bridge_hosts(rooms: Array[Dictionary], bridges: int, doline: bool) -> Array[int]:
    var candidates: Array[int] = []
    for index in range(1 if doline else 0, rooms.size()):
        if rooms[index].size.x >= 8 and rooms[index].size.z >= 7 \
                and str(rooms[index].archetype) not in NO_BRIDGE:
            candidates.append(index)
    candidates.sort_custom(func(a: int, b: int):
        return rooms[a].size.x * rooms[a].size.z > rooms[b].size.x * rooms[b].size.z)
    return candidates.slice(0, mini(bridges, candidates.size()))


## Rock bridges across the largest chambers, over a chasm opened below their floor. The chasm (a room volume)
## joins the voids; the bridge is a solid, subtracted after every void so the span stays rock.
static func _add_bridges(spec: Dictionary, rooms: Array[Dictionary], volumes: Array[Dictionary]) -> Array[Dictionary]:
    var candidates := rooms.filter(func(room: Dictionary): return room.size.x >= 8 and room.size.z >= 7 \
        and str(room.get("archetype", "")) not in NO_BRIDGE)
    candidates.sort_custom(func(a: Dictionary, b: Dictionary): return a.size.x * a.size.z > b.size.x * b.size.z)
    var bridges: Array[Dictionary] = []
    for index in mini(int(spec.bridges), candidates.size()):
        var room: Dictionary = candidates[index]
        var depth := clampf(float(room.size.y) * 0.6, 8, 24)
        # The bowl's roof intersects the chamber. Version 9 keeps a wide ledge around it, where the galleries
        # arrive (82 % of the radius), clear of the chasm's wall relief.
        var share := Vector2(0.6, 0.55) if int(spec.version) >= 9 else Vector2(0.78, 0.72)
        var turn := Basis(Vector3.UP, float(room.yaw))
        volumes.append({"kind": "room", "a": room.a + Vector3.DOWN * depth, "b": room.a + Vector3.DOWN * depth,
            "size": Vector3(room.size.x * share.x, depth + room.size.y * 0.5, room.size.z * share.y),
            "yaw": room.yaw, "e": room.e, "amp": room.amp, "freq": room.freq})
        bridges.append({"kind": "rock_bridge", "a": room.a + turn * Vector3(-room.size.x * 0.92, 0.4, 0),
            "b": room.a + turn * Vector3(room.size.x * 0.92, 0.4, 0),
            "size": Vector3(clampf(float(room.size.z) * 0.16, 2.5, 5.5), 5.0, minf(3.0, room.size.x * 0.045)),
            "level": room.level, "pit_depth": depth, "room": room})
    return bridges


static func _shuffle(values: Array[int], rng: RandomNumberGenerator) -> void:
    for index in range(values.size() - 1, 0, -1):
        var other := rng.randi_range(0, index)
        var swap := values[index]
        values[index] = values[other]
        values[other] = swap


static func _pillar_sites(spec: Dictionary, rooms: Array[Dictionary], rng: RandomNumberGenerator) -> Array[Dictionary]:
    var sites: Array[Dictionary] = []
    var hosts: Array[int] = []
    for index in rooms.size():
        var size: Vector3 = rooms[index].size
        if rooms[index].archetype in ["hall", "breakdown", "lobed", "flat", "doline"] and minf(size.x, size.z) >= 7.0 and size.y >= 3.0:
            hosts.append(index)
    if hosts.is_empty():
        return sites
    for index in int(spec.pillars):
        var host := hosts[rng.randi_range(0, hosts.size() - 1)]
        var size: Vector3 = rooms[host].size
        var angle := rng.randf_range(0, TAU)
        var fraction := rng.randf_range(0.25, 0.6)
        sites.append({"room": host, "offset": Vector3(cos(angle) * size.x * fraction, 0, sin(angle) * size.z * fraction),
            "radius": maxf(rng.randf_range(0.8, clampf(minf(size.x, size.z) * 0.12, 1.0, 4.0)), _column_min(spec))})
    return sites


## Version 9: the thinnest column the lattice still meshes round (COLUMN_MIN_CELLS of the base cell); 0 before.
static func _column_min(spec: Dictionary) -> float:
    if int(spec.version) < 9:
        return 0.0
    return COLUMN_MIN_CELLS * clampf(float(spec.width_m) / 4.0, 1.0, 1.5)


## Version 9: the columns holding up each forest room's roof, spaced to walk between them and clear of the
## doorways where galleries arrive. Same sites as pillars, which the mesher subtracts after every void.
static func _forest_columns(spec: Dictionary, rooms: Array[Dictionary], links: Array[Dictionary],
        rng: RandomNumberGenerator) -> Array[Dictionary]:
    var sites: Array[Dictionary] = []
    var thinnest := _column_min(spec)
    for index in rooms.size():
        var room: Dictionary = rooms[index]
        if room.archetype != "forest":
            continue
        var size: Vector3 = room.size
        var turn := Basis(Vector3.UP, float(room.yaw))
        var doorways: Array[Dictionary] = []
        for link in links:
            if int(link.from) == index:
                doorways.append({"at": link.a, "width": float(link.width)})
            if int(link.to) == index:
                doorways.append({"at": link.b, "width": float(link.width)})
        var count := clampi(int(size.x * size.z / 60.0), 5, 18)
        var placed: Array[Dictionary] = []
        for attempt in count * 6:
            var angle := rng.randf_range(0, TAU)
            var fraction := sqrt(rng.randf()) * 0.62
            var offset := Vector3(cos(angle) * size.x * fraction, 0, sin(angle) * size.z * fraction)
            var radius := maxf(rng.randf_range(0.6, clampf(minf(size.x, size.z) * 0.07, 0.8, 2.5)), thinnest)
            var at: Vector3 = room.a + turn * offset
            var clear := true
            for other in placed:
                clear = clear and (offset - (other.offset as Vector3)).length() >= radius + float(other.radius) + 2.6
            for door in doorways:
                var doorway: Vector3 = door.at
                clear = clear and Vector2(at.x - doorway.x, at.z - doorway.z).length() >= radius + float(door.width) * 0.5 + 2.0
            if clear:
                placed.append({"room": index, "offset": offset, "radius": radius})
            if placed.size() >= count:
                break
        sites.append_array(placed)
    return sites


## Version 9: candidate light shafts drawn from the seed, six per requested shaft: a chamber whose vault is
## high enough, a point under it, a pipe radius and the radius of its hole in the ground. _place_lights keeps
## those whose column up to the surface crosses nothing.
static func _light_sites(spec: Dictionary, ctx: Dictionary, rooms: Array[Dictionary],
        rng: RandomNumberGenerator) -> Array[Dictionary]:
    var sites: Array[Dictionary] = []
    var hosts: Array[int] = []
    for index in rooms.size():
        if not (ctx.doline and index == 0) and float(rooms[index].size.y) >= 6.0 and rooms[index].archetype != "forest":
            hosts.append(index)
    if hosts.is_empty():
        return sites
    for attempt in int(spec.light_shafts) * 6:
        var host := hosts[rng.randi_range(0, hosts.size() - 1)]
        var size: Vector3 = rooms[host].size
        var angle := rng.randf_range(0, TAU)
        var fraction := rng.randf_range(0.0, 0.4)
        var radius := rng.randf_range(1.2, clampf(minf(size.x, size.z) * 0.2, 1.5, 3.5))
        sites.append({"room": host, "offset": Vector3(cos(angle) * size.x * fraction, 0, sin(angle) * size.z * fraction),
            "radius": radius, "rim": radius * rng.randf_range(0.75, 1.3), "reach": float(rooms[host].radius)})
    return sites


## Keeps the light shaft candidates whose column, from the chamber vault to the lattice's top plane, crosses no
## other void, column or bridge, up to the profile's count. Appends their vertical pipes, open on the top plane
## where CavePortal.build_skylight raises their walls to the ground.
static func _place_lights(spec: Dictionary, ctx: Dictionary, sites: Array[Dictionary], rooms: Array[Dictionary],
        volumes: Array[Dictionary], solids: Array[Dictionary], top: float, cell: float) -> Array[Dictionary]:
    var lights: Array[Dictionary] = []
    var rough := float(spec.roughness)
    var erode := float(spec.get("gallery_noise", 0.0))
    for site in sites:
        if lights.size() >= int(spec.light_shafts):
            break
        var room: Dictionary = rooms[int(site.room)]
        var local: Vector3 = site.offset
        var size: Vector3 = room.size
        var e := float(room.e)
        var k := float(room.k)
        var r := pow(pow(absf(local.x) / size.x, e) + pow(absf(local.z) / size.z, e), 1.0 / e)
        var tilt: Vector2 = room.tilt
        var floor_y := float(room.a.y) + tilt.x * local.x + tilt.y * local.z
        var roof := size.y * pow(maxf(0.0, 1.0 - pow(minf(r, 1.0), k)), 1.0 / k)
        var radius := maxf(float(site.radius), cell * 1.2)
        # The pipe's rounded foot stays above the floor and its relief (a light shaft never holes it), and below
        # the vault, where the chamber's own air is, so the shaft opens into the chamber.
        var vault := floor_y + roof - float(room.amp) * NOISE_PEAK - 0.5
        var start := floor_y + maxf(roof * 0.5, 1.0 + float(room.terrace) + float(room.floor_rough) * NOISE_PEAK + radius)
        if start - radius > vault - 1.0:
            continue
        var center: Vector3 = room.a + Basis(Vector3.UP, float(room.yaw)) * local
        if center.z < float(ctx.entry_end) + 12.0:
            continue
        var axis := Vector2(center.x, center.z)
        var amp := rough * clampf(radius * 0.15, 0.2, 0.8) * (1.0 + erode)
        if not _column_clear(axis, radius + amp * NOISE_PEAK + 1.5, start - radius, vault, top, room, float(site.reach),
                volumes, solids):
            continue
        volumes.append({"kind": "shaft", "a": Vector3(center.x, start, center.z), "b": Vector3(center.x, top + 40.0, center.z),
            "size": Vector3.ONE * radius, "amp": amp, "freq": 1.0 / clampf(radius * 1.2, 2.5, 8.0)})
        lights.append({"center": axis, "radius": radius + amp * NOISE_PEAK, "rim": maxf(float(site.rim), cell),
            "room": int(site.room), "top": top, "foot": start - radius})
    return lights


## True when a light shaft's pipe, rising along [param axis] from [param foot] to the lattice's [param top],
## pierces no floor: no other void whose floor lies above the host chamber's [param vault] comes within
## [param reach]. Voids beside the chamber that merely rise past its vault only merge with the pipe, which is
## harmless, except another pipe reaching the top plane (doline throat, light shafts): their open loops must stay
## apart. Columns and bridges must not plug the pipe either.
static func _column_clear(axis: Vector2, reach: float, foot: float, vault: float, top: float, host: Dictionary,
        host_reach: float, volumes: Array[Dictionary], solids: Array[Dictionary]) -> bool:
    var host_center := Vector2(host.a.x, host.a.z)
    for volume in volumes:
        var a: Vector3 = volume.a
        var b: Vector3 = volume.b
        var size: Vector3 = volume.size
        var relief := absf(float(volume.get("amp", 0.0))) * NOISE_PEAK
        var gap := Geometry2D.get_closest_point_to_segment(axis, Vector2(a.x, a.z), Vector2(b.x, b.z)).distance_to(axis)
        var blocked := false
        if str(volume.kind) == "room":
            # The host chamber, its lobes and the pit under its bridge share its centre.
            blocked = host_center.distance_to(Vector2(a.x, a.z)) > host_reach \
                and gap <= maxf(size.x, size.z) + relief + reach and _support(volume).position.y + 3.0 >= vault - 1.0
        elif str(volume.kind) == "tunnel":
            var grow := erosion_growth(size, maxf(float(volume.get("erode_a", 0.0)), float(volume.get("erode_b", 0.0))))
            blocked = gap <= size.x + grow.x + relief + reach and minf(a.y, b.y) - relief - grow.x >= vault - 1.0
        elif maxf(a.y, b.y) >= top:  # the doline throat and the other light shafts
            blocked = gap <= size.x + relief + reach + 4.0
        if blocked:
            return false
    for solid in solids:
        var near := Geometry2D.get_closest_point_to_segment(axis, Vector2(solid.a.x, solid.a.z), Vector2(solid.b.x, solid.b.z))
        # A rock bridge lies on the chamber floor (CaveNetworkMesher: at most size.z + 0.7 above its axis).
        var crown := float(solid.a.y) + float(solid.size.y) if solid.kind == "pillar" \
            else maxf(float(solid.a.y), float(solid.b.y)) + float(solid.size.z) + 0.7
        if near.distance_to(axis) <= float(solid.size.x) * 1.2 + reach + 1.0 and crown >= foot - 0.5:
            return false
    return true


## Largest outward reach (m) the version 9 erosion adds to a gallery section: x horizontal, y up.
static func erosion_growth(size: Vector3, erode: float) -> Vector2:
    return Vector2(erode * (ERODE_WIDEN + ERODE_SHIFT) * size.x,
        erode * (minf(ERODE_RISE * size.y, ERODE_RISE_MAX_M) + minf(ERODE_BELL * size.y, ERODE_BELL_MAX_M)))


# ---------------------------------------------------------------- volumes

static func _emit(spec: Dictionary, ctx: Dictionary, sources: Array[Dictionary], descriptors: Array[Dictionary],
        pillar_sites: Array[Dictionary], cell: float, light_sites: Array[Dictionary] = []) -> Dictionary:
    var volumes: Array[Dictionary] = []
    var rooms: Array[Dictionary] = []
    var links: Array[Dictionary] = []
    var entry_end := float(ctx.entry_end)
    var network_end := float(ctx.network_end)
    var rough := float(spec.roughness)
    var erode := float(spec.get("gallery_noise", 0.0))
    var spans: Array[Dictionary] = []  # version 9 rock bridges over passable pits
    var passable: Array[Dictionary] = []  # their galleries, sunk once every gallery is traced
    for source in sources:
        var room := {"kind": "room", "a": source.a, "b": source.a, "level": source.level, "archetype": source.archetype,
            "yaw": source.yaw, "e": source.e, "k": source.k, "tilt": source.tilt, "floor_rough": source.floor_rough,
            "amp": source.amp, "freq": source.freq, "terrace": source.terrace, "basin": source.basin,
            "basin_r": source.basin_r,
            # The lattice must resolve the smallest chambers: never thinner than 1.5 cells.
            "size": Vector3(maxf(source.size.x, cell * 1.5), maxf(source.size.y, cell * 2.0), maxf(source.size.z, cell * 1.5))}
        if ctx.v9:
            room.rim_calm = true  # floor relief calms down on the doorway ring
        volumes.append(room)
        rooms.append(room)
        var turn := Basis(Vector3.UP, float(source.yaw))
        for lobe: Dictionary in source.lobes:
            var center: Vector3 = source.a + turn * (lobe.offset as Vector3)
            volumes.append({"kind": "room", "a": center, "b": center, "yaw": source.yaw, "e": 2.0, "k": lobe.k,
                "tilt": source.tilt, "floor_rough": source.floor_rough, "amp": source.amp, "freq": source.freq,
                "size": Vector3(maxf(lobe.size.x, cell * 1.5), maxf(lobe.size.y, cell * 2.0), maxf(lobe.size.z, cell * 1.5))})
    if not ctx.doline:
        # The shared boundary is stitched exactly; v9 no longer needs a smooth artificial entry tube.
        _path(volumes, links, [Vector3(0, 0, entry_end - 3), Vector3(0, 0, entry_end + 8)], float(spec.width_m),
            float(spec.height_m), rough * 0.6 if ctx.v9 else 0.0, 0.16, ctx, false, false, "walk", false,
            erode * 0.65 if ctx.v9 else 0.0)
    for link in descriptors:
        var width := maxf(float(link.width), cell * 2.2)
        var height := maxf(float(link.height), cell * 1.8)
        var amp := rough * clampf(width * 0.12, 0.25, 2.0)
        var freq := 1.0 / clampf(width * 0.9, 2.5, 14.0)
        var a: Vector3 = link.a
        var b: Vector3 = link.b
        var dead_end := str(link.role) == "branch"
        var entrance := int(link.from) < 0
        if entrance:
            amp = rough * clampf(width * 0.08, 0.2, 0.8) if ctx.v9 else 0.0
        elif erode > 0.0:
            amp += erode * clampf(width * 0.08, 0.2, 1.0)  # eroded walls: deeper scallops and flutes
        var land_a: Variant = _landing(sources, int(link.from), a) if ctx.v9 else null
        var land_b: Variant = _landing(sources, int(link.to), b) if ctx.v9 and str(link.kind) != "perched" else null
        var points: Array[Vector3] = []
        match str(link.kind):
            "shaft":
                var radius := maxf(cell * 1.2, clampf(width * 0.3, 1.8, 4.0))
                var upper := int(link.from) if a.y >= b.y else int(link.to)
                var lower := int(link.to) if a.y >= b.y else int(link.from)
                var rim := a if a.y >= b.y else b
                var bottom := b if a.y >= b.y else a
                bottom += Vector3.UP * (minf(float(sources[lower].size.y) * 0.4, 4.0) if lower >= 0 else 0.0)
                # The hole opens at the end of a short side passage beyond the upper chamber's wall, never in
                # its floor: a wide mouth on a small chamber's rim would swallow it with its other doorways.
                var outward := Vector3(rim.x - sources[upper].a.x, 0, rim.z - sources[upper].a.z).normalized() \
                    if upper >= 0 else Vector3.BACK
                var top := rim + outward * (radius + 3.0 + float(sources[upper].radius) * 0.25 if upper >= 0 else 0.0)
                top.z = clampf(top.z, float(ctx.entry_end) + radius + 8.0, maxf(float(ctx.entry_end) + radius + 8.0,
                    float(ctx.network_end) - radius - 8.0))
                _path(volumes, links, [rim, top], width, height, amp, freq, ctx, false, true, "walk", false, erode)
                volumes.append({"kind": "shaft", "a": top, "b": bottom, "size": Vector3.ONE * radius, "amp": amp, "freq": freq})
                links.append({"a": top, "b": bottom, "points": [top, bottom], "width": radius * 2.0,
                    "height": top.distance_to(bottom), "dead_end": dead_end, "drop": true, "kind": "shaft"})
            "spiral":
                _path(volumes, links, _spiral(a, b, width), width, height, amp, freq, ctx, dead_end, true, "spiral",
                    false, erode)
            "perched":
                points = _route(volumes, links, a, b + Vector3.UP * float(link.perch), width, height, amp, freq, ctx,
                    dead_end, "perched", false, erode, land_a)
            "pit":
                points = _route(volumes, links, a, b, width, height, amp, freq, ctx, dead_end, "pit", false, erode,
                    land_a, land_b)
                var middle := points[points.size() / 2]
                volumes.append({"kind": "shaft", "a": middle + Vector3.UP * 0.5,
                    "b": middle + Vector3.DOWN * float(link.pit_depth), "size": Vector3.ONE * maxf(float(link.pit_radius), width * 0.75),
                    "amp": amp * 0.5, "freq": freq})
            _:
                points = _route(volumes, links, a, b, width, height, amp, freq, ctx, dead_end, str(link.kind), entrance,
                    erode, land_a, land_b)
                if link.has("pit_pass") and points.size() >= 3:
                    passable.append({"link": link, "points": points, "width": width, "amp": amp, "freq": freq})
        if str(link.get("section", "")) == "keyhole" and not points.is_empty():
            # Keyhole: the phreatic tube left perched over the vadose canyon that later cut down its floor.
            var raised: Array[Vector3] = []
            for point in points:
                raised.append(point + Vector3.UP * height * 0.55)
            _path(volumes, links, raised, maxf(float(link.tube_width), cell * 2.2), maxf(float(link.tube_height), cell * 1.8),
                amp, freq, ctx, dead_end, false, "keyhole", false, erode)
    var pits: Array[Dictionary] = []
    for pending in passable:
        _passable_pit(volumes, spans, pits, links, pending)
    var pillars: Array[Dictionary] = []
    for site in pillar_sites:
        var room: Dictionary = rooms[int(site.room)]
        var tilt: Vector2 = room.tilt
        var sink := (absf(tilt.x) + absf(tilt.y)) * Vector2(room.size.x, room.size.z).length() \
            + float(room.floor_rough) * NOISE_PEAK + 2.0
        var point: Vector3 = room.a + Basis(Vector3.UP, float(room.yaw)) * (site.offset as Vector3) + Vector3.DOWN * sink
        var radius := maxf(float(site.radius), cell)
        pillars.append({"kind": "pillar", "a": point, "b": point, "level": room.level,
            "size": Vector3(radius, float(room.size.y) + sink * 2.0 + 2.0, radius)})
        if ctx.v9:
            # Fluted, irregular columns instead of turned cylinders: the walls' gradient relief, scaled to the column
            # (its peak stays within the mesher's 3 m support margin).
            pillars.back().amp = clampf(radius * 0.2, 0.15, 0.9) * (0.5 + rough)
            pillars.back().freq = 1.0 / clampf(radius * 1.3, 1.5, 6.0)
    # A doline lands on its chamber's floor: no chasm under the throat.
    var bridges := _add_bridges(spec, rooms.slice(1) if ctx.doline else rooms, volumes)
    var tail_floor := 0.0
    if bool(spec.exit_open) or bool(ctx.has_crawls):
        var last: Dictionary = rooms[0]
        for room in rooms:
            if room.a.z > last.a.z:
                last = room
        tail_floor = -float(spec.depth_m) if bool(spec.exit_open) else float(last.a.y)
        var exit_point := Vector3(0, tail_floor, network_end + 3)
        var before_exit := exit_point - Vector3(0, 0, 11)
        _path(volumes, links, [last.a, before_exit], float(spec.width_m), float(spec.height_m),
            rough * 0.3, 0.2, ctx, false, false)
        _path(volumes, links, [before_exit, exit_point],
            float(spec.width_m if bool(ctx.has_crawls) else spec.exit_width_m),
            float(spec.height_m if bool(ctx.has_crawls) else spec.exit_height_m), 0.0, 0.2, ctx, false, false)
    var bounds := AABB(Vector3(-float(spec.width_m), -1, entry_end), Vector3(float(spec.width_m) * 2, 2, 1))
    for volume in volumes:
        bounds = bounds.merge(_support(volume))
    var extra := {}
    # Doline throat and light shafts rise past every other void and are cut by the lattice's top plane: those
    # open loops are where their walls, built against the terrain, take over.
    var top := bounds.end.y + 0.5
    if ctx.doline:
        var chamber: Dictionary = rooms[0]
        var radius := maxf(float(ctx.throat), cell * 2.0)
        var axis := Vector3(chamber.a.x, 0.0, chamber.a.z)
        # Version 9 keeps the throat's rounded foot above the chamber floor; a wide version 8 throat dug a bowl
        # in it, under the landing.
        var foot := float(chamber.size.y) * 0.6
        if ctx.v9:
            foot = maxf(foot, radius + 1.0)
        volumes.append({"kind": "shaft", "a": chamber.a + Vector3.UP * foot,
            "b": axis + Vector3.UP * (top + 40.0), "size": Vector3.ONE * radius,
            "amp": rough * clampf(radius * 0.12, 0.3, 1.5), "freq": 1.0 / clampf(radius * 0.8, 2.5, 12.0)})
        extra = {"sky": {"center": Vector2(axis.x, axis.z), "radius": radius, "top": top},
            "walk_start": chamber.a + Vector3.UP * 0.5}
    var lights := _place_lights(spec, ctx, light_sites, rooms, volumes, pillars + bridges + spans, top, cell)
    if not lights.is_empty():
        extra.lights = lights
    volumes.append_array(pillars)  # subtract only after all chambers and galleries have been unioned
    volumes.append_array(bridges)
    volumes.append_array(spans)
    for volume in pillars + bridges + spans:
        bounds = bounds.merge(_support(volume))
    if ctx.doline or not lights.is_empty():
        bounds.size.y = top - bounds.position.y
    bounds.position.z = entry_end
    bounds.size.z = network_end - entry_end
    var footprint := bounds
    if bool(ctx.has_crawls):
        var width := maxf(float(spec.width_m), float(spec.exit_width_m) if bool(spec.exit_open) else 0.0) + 4
        var height := maxf(float(spec.height_m), float(spec.exit_height_m) if bool(spec.exit_open) else 0.0)
        footprint = footprint.merge(AABB(Vector3(-width, tail_floor - 1, network_end), Vector3(width * 2, height + 1, 24)))
    var graph := {"volumes": volumes, "rooms": rooms, "links": links, "pillars": pillars, "bounds": bounds,
        "bridges": bridges, "spans": spans, "pits": pits, "tail_floor": tail_floor, "footprint": footprint, "cell_m": cell,
        "entry_end": entry_end,
        "estimate": _estimate_samples(volumes, bounds, cell)}
    graph.merge(extra)
    return graph


## The pit of a passable gallery (see _passable_pits), at the middle of its route: sunk against one wall
## beside the ledge, or across the whole floor under a rock bridge, a solid subtracted after every void. The
## bridge joins two route points past the pit's rim, so it follows the floor's grade; its ends sink just under
## the floor and its nearly flat top (8 cm of undulation) rises 35 cm over the pit, wide enough to walk. No
## pit where it would cut another gallery, beside this one or below it.
static func _passable_pit(volumes: Array[Dictionary], spans: Array[Dictionary], pits: Array[Dictionary],
        links: Array[Dictionary], pending: Dictionary) -> void:
    var link: Dictionary = pending.link
    var points: Array[Vector3] = pending.points
    var width := float(pending.width)
    var mid := points.size() / 2
    var middle := points[mid]
    var radius := float(link.pit_radius)
    var depth := float(link.pit_depth)
    var center := middle
    var span := {}
    if link.pit_pass == "bridge":
        var ends: Array[Vector3] = []
        for step: int in [-1, 1]:
            var index := mid + step
            while index > 0 and index < points.size() - 1 and _flat(points[index], middle) < radius + 1.0:
                index += step
            ends.append(points[index])
        if _flat(ends[0], middle) < radius + 1.0 or _flat(ends[1], middle) < radius + 1.0:
            return  # too short a route around the middle: no pit rather than one the span cannot cross
        # The straight span must stay over the winding gallery's floor: the pit is centred under it.
        center = (ends[0] + ends[1]) * 0.5
        if _flat(center, middle) > width * 0.2:
            return
        center.y = middle.y
        span = {"kind": "rock_bridge", "a": ends[0] + Vector3.DOWN * 0.15, "b": ends[1] + Vector3.DOWN * 0.15,
            "size": Vector3(clampf(width * 0.45, 1.8, 2.8), 2.2, 0.35), "wave": 0.08}
    else:
        var along := points[mid + 1] - points[mid - 1]
        center += Vector3(along.x, 0.0, along.z).normalized().cross(Vector3.UP) * float(link.pit_side) * width * 0.5
    var plan := Vector2(center.x, center.z)
    for other: Dictionary in links:
        if other.points == points:
            continue
        var others: Array = other.points
        for index in others.size() - 1:
            var a: Vector3 = others[index]
            var b: Vector3 = others[index + 1]
            var run := Vector2(b.x - a.x, b.z - a.z)
            var t := clampf((plan - Vector2(a.x, a.z)).dot(run) / maxf(run.length_squared(), 1.0e-6), 0.0, 1.0)
            var at := a.lerp(b, t)
            var near := _flat(at, center) < radius + float(other.width) * 0.5 + 1.0
            if near and at.y < center.y + 1.5 and at.y + float(other.height) > center.y - depth:
                return
    if not span.is_empty():
        spans.append(span)
    volumes.append({"kind": "shaft", "a": center + Vector3.UP * 0.5, "b": center + Vector3.DOWN * depth,
        "size": Vector3.ONE * radius, "amp": float(pending.amp) * 0.5, "freq": pending.freq})
    pits.append({"pass": link.pit_pass, "center": center, "radius": radius, "gallery": middle, "width": width})


## Horizontal distance between two points.
static func _flat(a: Vector3, b: Vector3) -> float:
    return Vector2(b.x - a.x, b.z - a.z).length()


## A meandering gallery from doorway [param a] to doorway [param b]. Version 9 passes through the chamber walls
## it crosses ([param land_a], [param land_b], see _landing): the grade and the meanders lie between them.
static func _route(volumes: Array[Dictionary], links: Array[Dictionary], a: Vector3, b: Vector3, width: float,
        height: float, amp: float, freq: float, ctx: Dictionary, dead_end: bool, kind: String,
        entrance: bool = false, erode: float = 0.0, land_a: Variant = null, land_b: Variant = null) -> Array[Vector3]:
    var control: Array[Vector3] = [a]
    var start := a
    var finish := b
    if land_a != null and (land_a as Vector3).distance_to(a) > 1.0:
        start = land_a
        control.append(start)
    if land_b != null and (land_b as Vector3).distance_to(b) > 1.0:
        finish = land_b
    var length := start.distance_to(finish)
    if length > 12.0:
        # Meanders: more bends on longer passages, their phase fixed by the ends (no seed needed here).
        var side := (finish - start).cross(Vector3.UP).normalized()
        var bends := clampi(int(length / 16.0), 1, 6)
        var amount := minf(length * 0.12, width * 1.6 + 2.0)
        var phase := a.x * 0.19 + b.z * 0.13 - a.z * 0.07
        for index in range(1, bends + 1):
            var t := float(index) / (bends + 1)
            control.append(start.lerp(finish, t) + side * amount * sin(phase + index * 2.1) * sin(PI * t))
    if finish != b:
        control.append(finish)
    control.append(b)
    return _path(volumes, links, control, width, height, amp, freq, ctx, dead_end, true, kind, entrance, erode)


## Catmull-Rom through the control points, every ~5 m. Interior points stay clear of the entrance and far
## end planes: only the entrance stub and the exit may cross them, or the portals would be corrupted.
## [param erode] (version 9) is the gallery erosion; the entrance gallery fades it in over ERODE_RAMP_M.
static func _path(volumes: Array[Dictionary], links: Array[Dictionary], control: Array, width: float, height: float,
        amp: float, freq: float, ctx: Dictionary, dead_end: bool, clamp_z: bool, kind: String = "walk",
        entrance: bool = false, erode: float = 0.0) -> Array[Vector3]:
    var points: Array[Vector3] = [control[0]]
    for segment in control.size() - 1:
        var a: Vector3 = control[maxi(0, segment - 1)]
        var b: Vector3 = control[segment]
        var c: Vector3 = control[segment + 1]
        var d: Vector3 = control[mini(control.size() - 1, segment + 2)]
        var steps := maxi(1, int(ceil(b.distance_to(c) / 5.0)))
        for step in range(1, steps + 1):
            var t := float(step) / steps
            points.append(0.5 * (2 * b + (-a + c) * t + (2*a - 5*b + 4*c - d) * t*t + (-a + 3*b - 3*c + d) * t*t*t))
    if clamp_z:
        var swell := width * 0.5 * (ERODE_WIDEN + ERODE_SHIFT) * erode
        var low := float(ctx.entry_end) + (8.0 if entrance else width * 0.5 + 4.0 + amp * NOISE_PEAK + swell)
        var high := float(ctx.network_end) - width * 0.5 - 4.0 - amp * NOISE_PEAK - swell
        for index in points.size():
            points[index].z = clampf(points[index].z, low, maxf(low, high))
        if ctx.v9:
            # Clamping can stack points on the same plane: their drop would become a vertical step. Keep one.
            var kept: Array[Vector3] = [points[0]]
            for index in range(1, points.size()):
                var last: Vector3 = kept.back()
                var flat := Vector2(points[index].x - last.x, points[index].z - last.z).length()
                if flat >= 1.0 or index == points.size() - 1:
                    kept.append(points[index])
            points = kept
    var run := 0.0
    for index in points.size() - 1:
        var volume := {"kind": "tunnel", "a": points[index], "b": points[index + 1],
            "size": Vector3(width * 0.5, height, width * 0.5), "amp": amp, "freq": freq,
            "continues_a": index > 0, "continues_b": index < points.size() - 2}
        if ctx.v9:
            volume.grade_reach = true  # the floor grade runs on under the neighbouring segments' rounded ends
        if erode > 0.0:
            var next := run + points[index].distance_to(points[index + 1])
            volume.erode_a = erode * (smoothstep(0.0, ERODE_RAMP_M, run) if entrance else 1.0)
            volume.erode_b = erode * (smoothstep(0.0, ERODE_RAMP_M, next) if entrance else 1.0)
            run = next
        volumes.append(volume)
    links.append({"a": control[0], "b": control[-1], "points": points, "width": width, "height": height,
        "dead_end": dead_end, "kind": kind})
    return points


## A walkable helix replacing a gallery too steep to climb: same ends, a 25° grade around a vertical axis.
static func _spiral(a: Vector3, b: Vector3, width: float) -> Array[Vector3]:
    var radius := clampf(width * 1.6, 6.0, 16.0)
    var turns := maxf(0.75, absf(b.y - a.y) / (TAU * radius * SPIRAL_SLOPE))
    var center := (a + b) * 0.5
    var start := atan2(a.x - center.x, a.z - center.z)
    var points: Array[Vector3] = [a]
    var steps := int(ceil(turns * 12.0))
    for index in range(1, steps):
        var t := float(index) / steps
        var angle := start + TAU * turns * t
        points.append(Vector3(center.x + sin(angle) * radius, lerpf(a.y, b.y, t), center.z + cos(angle) * radius))
    points.append(b)
    return points


## Mirrors CaveNetworkMesher.ShapeBounds: conservative support of one volume.
static func _support(volume: Dictionary) -> AABB:
    var a: Vector3 = volume.a
    var b: Vector3 = volume.b
    var size: Vector3 = volume.size
    var relief := absf(float(volume.get("amp", 0.0))) * NOISE_PEAK + 3.0
    match str(volume.kind):
        "room":
            var reach := Vector2(size.x, size.z).length()
            var tilt: Vector2 = volume.get("tilt", Vector2.ZERO)
            var drop := (absf(tilt.x) + absf(tilt.y)) * reach + absf(float(volume.get("floor_rough", 0.0))) * NOISE_PEAK \
                + float(volume.get("terrace", 0.0)) + float(volume.get("basin", 0.0))
            var low := a - Vector3(reach + relief, drop + relief, reach + relief)
            var high := a + Vector3(reach + relief, size.y + drop + relief, reach + relief)
            return AABB(low, high - low)
        "shaft":
            var low := a.min(b) - Vector3.ONE * (size.x + relief)
            return AABB(low, a.max(b) + Vector3.ONE * (size.x + relief) - low)
        "rock_bridge":
            var low := a.min(b) - Vector3(size.x + 3, size.y + 3, size.x + 3)
            return AABB(low, a.max(b) + Vector3(size.x + 3, size.z + 3, size.x + 3) - low)
        "pillar":
            var low := a - Vector3(size.x + 3, 3, size.x + 3)
            return AABB(low, a + Vector3(size.x + 3, size.y + 3, size.x + 3) - low)
    # Eroded galleries (version 9) swell sideways and up; their drifting section shifts the floor grade a little,
    # and a floor grade continued under the neighbours' rounded ends lowers or lifts those ends.
    var grow := erosion_growth(size, maxf(float(volume.get("erode_a", 0.0)), float(volume.get("erode_b", 0.0))))
    var lift := 0.0
    var run := Vector2(b.x - a.x, b.z - a.z).length()
    if volume.get("grade_reach", false) and run > 0.000001 and absf(b.y - a.y) <= run:
        var extend := maxf(0.5, (size.x * (1.0 + ERODE_WIDEN + ERODE_SHIFT) + absf(float(volume.amp)) * NOISE_PEAK) / run)
        lift = absf(b.y - a.y) * (extend - 0.5)
    var side := size.x + relief + grow.x
    var low := a.min(b) - Vector3(side, relief + grow.x * 0.7 + lift, side)
    return AABB(low, a.max(b) + Vector3(side, size.y + relief + grow.y + lift, side) - low)


## Samples the sparse mesher allocates: the distinct 16³ blocks touched by the volume supports, indexed
## exactly as CaveNetworkMesher.BuildSparse does.
static func _estimate_samples(volumes: Array[Dictionary], bounds: AABB, cell: float) -> int:
    var counts := Vector3i(int(ceil(bounds.size.x / cell)) + 1, int(ceil(bounds.size.y / cell)) + 1,
        int(ceil(bounds.size.z / cell)) + 1)
    var spacing := Vector3(cell, cell, bounds.size.z / (counts.z - 1))
    var top := counts - Vector3i.ONE
    var blocks := {}
    for volume in volumes:
        var box := _support(volume)
        var low := Vector3i(((box.position - bounds.position) / spacing).floor()).clamp(Vector3i.ZERO, top) / 16
        var high := Vector3i(((box.end - bounds.position) / spacing).ceil()).clamp(Vector3i.ZERO, top) / 16
        for z in range(low.z, high.z + 1):
            for y in range(low.y, high.y + 1):
                for x in range(low.x, high.x + 1):
                    blocks[Vector3i(x, y, z)] = true
    return blocks.size() * 4096


static func display_name(archetype: String) -> String:
    return NAMES.get(archetype, archetype)
