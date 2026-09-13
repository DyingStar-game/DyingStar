"""
Rocky landform — 9 biomes.
"""

from ..model import BiomeCategory, Field, Range, ValueMap
from ..rocks import rock_fields

CATEGORY = BiomeCategory('rocky_landform')

CATEGORY.biome(
    22, 'raw_mountain', '#7a7a7a',
    ('A high-altitude summit or slope located above the lichen growth limit. The landscape '
     'is dominated by exposed bedrock'),
    planet_type='terrestrial',
)

CATEGORY.biome(
    23, 'alpine_mountain', '#6a8a5a',
    ('A mountain zone located between the tree line and the permanent snow line. '
     'Characterized by short grasslands (alpine meadows) and flora adapted to intense UV '
     'radiation and strong winds'),
    planet_type='terrestrial',
)

CLIFF_SHAPES = [
    ("Straight — clean vertical face", "straight"),
    ("Eroded — rounded, scree at the foot", "eroded"),
    ("Fractured — blocky, stepped face", "fractured"),
    ("Spiky — needles and pinnacles along the edge", "spiky"),
]

CATEGORY.biome(
    24, 'cliff', '#6e6e6e',
    ('Rocky escarpment with a near-vertical face.  Drawn as the crest line: the HIGH side is '
     'on the LEFT of the drawing direction.'),
    geom='LineString',
    direction_marker=True,
    planet_type='terrestrial',
    terrain_modifier=True,
    fields=[
        Field('height', 'double', 'Face height (metres)', widget=Range(1, 5000, 1)),
        Field('shape', 'string', 'Face shape', widget=ValueMap(CLIFF_SHAPES),
              default="'eroded'"),
        *rock_fields(),
    ],
)

CANYON_PROFILES = [
    ("V — river-cut, sloping walls", "v"),
    ("U — glacial, flat floor", "u"),
    ("Slot — narrow, vertical walls", "slot"),
]

CATEGORY.biome(
    25, 'canyon', '#8a5a3a',
    'Deep gorge with steep walls.  Drawn as the floor centreline.',
    geom='LineString',
    planet_type='terrestrial',
    terrain_modifier=True,
    fields=[
        Field('depth', 'double', 'Depth below the surrounding terrain (metres)',
              widget=Range(1, 5000, 1)),
        Field('width_top', 'double', 'Rim-to-rim width (metres)', widget=Range(1, 20000, 1)),
        Field('width_bottom', 'double', 'Floor width (metres)', widget=Range(0.5, 20000, 0.5)),
        Field('profile', 'string', 'Cross-section', widget=ValueMap(CANYON_PROFILES),
              default="'v'"),
        *rock_fields(),
    ],
)

CATEGORY.biome(
    61, 'pressure_canyon', '#4a3a2a',
    ('A deep rift where atmospheric pressure is higher than at the surface. Temperature '
     'increases with depth'),
    geom='LineString',
    planet_type='atmosphere',
    terrain_modifier=True,
    fields=[
        Field('depth', 'integer', 'Canyon depth in metres',
              widget=Range(0, 5000, 1)),
    ],
)

CATEGORY.biome(
    73, 'cave', '#7050a0',
    ('A natural underground network. Depending on the planet, it may be adorned with ice '
     'stalactites, limestone, or even exotic crystals'),
    geom='Point',
    planet_type='mineral',
    fields=rock_fields(underground=True),
)

CATEGORY.biome(
    87, 'mining_cave', '#8a6a4a',
    ('An artificial or natural cavity modified for mineral extraction. It is distinguished '
     'by fractured walls and supporting structures'),
    geom='Point',
    planet_type='artificial',
    fields=rock_fields(underground=True),
)

CATEGORY.biome(
    93, 'arachnoide', '#6a5a50',
    'Radial fracture extending beyond the circular fracture',
    planet_type='terrestrial',
)

CATEGORY.biome(
    95, 'perforated_limestone', '#c8b898',
    '(beware of trypophobia) composed of perforated limestone',
    planet_type='terrestrial',
)
