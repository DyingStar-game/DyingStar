class_name CaveTerrainFit
extends RefCounted
## Heading suggestions read from the game's native relief. The entrance itself is fitted by CavePortal.fit.
## Call only after CavePlanetRegistry.tiles_ready for each candidate footprint.


static func heading_probes(placement: CavePlacement) -> Array[CavePlacement]:
    var probes: Array[CavePlacement] = []
    for index in 8:
        var probe: CavePlacement = placement.duplicate(true)
        probe.profile = placement.profile.duplicate(true)
        probe.heading_deg = -180.0 + index * 45.0
        probe.profile.length_m = 100.0
        probe.profile.exit_open = false
        probe.profile.entrance_type = "ramp"
        probe.ramp_length_m = 55.0
        probes.append(probe)
    return probes


static func uphill_heading(data: PlanetData, probes: Array[CavePlacement]) -> Dictionary:
    var best := {"heading": 0.0, "rise_m": -INF}
    for probe in probes:
        var rise := 0.0
        for distance in [30.0, 60.0, 90.0]:
            rise += CaveEntrance.ground_point(data, probe, 0.0, distance).y / 3.0
        if rise > float(best.rise_m):
            best = {"heading": probe.heading_deg, "rise_m": rise}
    return best
