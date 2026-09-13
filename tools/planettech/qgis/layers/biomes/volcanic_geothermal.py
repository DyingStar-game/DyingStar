"""
Volcanic geothermal — 16 biomes.
"""

from ..model import BiomeCategory, Field, Range, ValueMap
from ..rocks import rock_fields

CATEGORY = BiomeCategory('volcanic_geothermal')

VOLCANO_SHAPES = [
    ("Cone — steep stratovolcano", "cone"),
    ("Shield — broad, gently sloping", "shield"),
    ("Caldera — collapsed summit basin", "caldera"),
]

CATEGORY.biome(
    26, 'active_volcano', '#4a2c2a',
    ('A volcano in eruption or with significant internal magmatic activity.  Placed as a '
     'point: Godot builds the edifice from the parameters below.'),
    geom='Point',
    planet_type='volcanic',
    terrain_modifier=True,
    fields=[
        Field('base_diameter', 'double', 'Diameter at the base (metres)',
              widget=Range(100, 200000, 100)),
        Field('height', 'double', 'Height above the surrounding terrain (metres)',
              widget=Range(10, 15000, 10)),
        Field('shape', 'string', 'Edifice shape', widget=ValueMap(VOLCANO_SHAPES),
              default="'cone'"),
        Field('crater_diameter', 'double', 'Summit crater / caldera diameter (metres)',
              widget=Range(0, 50000, 10)),
        Field('has_lava_lake', 'integer', '1 = the crater holds a lava lake',
              widget=Range(0, 1, 1), default='0'),
        *rock_fields(),
    ],
)

CATEGORY.biome(
    27, 'volcanic_basalt', '#2a2a2a',
    ('A plain of dense, dark, extrusive igneous rock. Rapid surface cooling creates a '
     'fine-grained rock, often structured into vast plateaus'),
    planet_type='volcanic',
)

CATEGORY.biome(
    28, 'lava_field', '#1a0a0a',
    'Extent of solidified lava exhibiting varied surface morphologies',
    planet_type='volcanic',
)

CATEGORY.biome(
    29, 'lava_lake', '#cc3300',
    ('A depression filled with liquid magma, kept molten by thermal convection.  Drawn as an '
     'outline; the lake inside a volcano crater is the volcano\'s has_lava_lake instead.'),
    planet_type='volcanic',
    fields=[
        Field('depth', 'double', 'Lake depth (metres)', widget=Range(1, 2000, 1)),
        *rock_fields(),
    ],
)

CATEGORY.biome(
    30, 'fumarole', '#8a7a5a',
    ('A single volcanic gas vent, placed by hand.  For an area Godot fills on its own, '
     'draw a fumarole field instead.'),
    geom='Point',
    planet_type='volcanic',
    fields=[
        Field('radius', 'double', 'Vent radius (metres)', widget=Range(0.5, 200, 0.5)),
        Field('intensity', 'double', 'Emission intensity 0.0-1.0', widget=Range(0.0, 1.0, 0.05),
              default='0.5'),
        *rock_fields(),
    ],
)

CATEGORY.biome(
    107, 'fumarole_field', '#a08a60',
    'An area Godot scatters fumaroles over at the given density.',
    planet_type='volcanic',
    fields=[
        Field('density', 'double', 'Vents per km²', widget=Range(0.1, 500, 0.1)),
        Field('radius', 'double', 'Typical vent radius (metres)', widget=Range(0.5, 200, 0.5)),
        Field('intensity', 'double', 'Emission intensity 0.0-1.0', widget=Range(0.0, 1.0, 0.05),
              default='0.5'),
        *rock_fields(),
    ],
)

CATEGORY.biome(
    31, 'geothermal', '#6a8a6a',
    ('A surface hydrothermal system comprising hot springs and pools saturated with '
     'dissolved minerals. The interaction between water and heat creates deposits and '
     'geysers'),
    planet_type='volcanic',
)

CATEGORY.biome(
    32, 'obsidian_field', '#0a0a1a',
    ('A rapidly cooled lava flow that did not crystallize, forming a sharp, black volcanic '
     'glass'),
    planet_type='volcanic',
)

CATEGORY.biome(
    33, 'ash_desert', '#4a4a4a',
    ('A thick layer of ash deposited after an explosive eruption. The landscape is '
     'monochrome, arid, and the soil is very loose'),
    planet_type='volcanic',
)

CATEGORY.biome(
    34, 'magmatic_crust', '#3a1a0a',
    ('An unstable zone where a thin layer of solidified rock covers a shallow magma '
     'reservoir. It exhibits extremely high surface heat flow and risks of collapse'),
    planet_type='volcanic',
)

CATEGORY.biome(
    53, 'ice_geyser', '#d8e8f8',
    ('A cryovolcanic phenomenon where plumes of water vapor, nitrogen, or methane are '
     'expelled from the depths'),
    geom='Point',
    planet_type='cryo',
    terrain_modifier=True,
    fields=[
        Field('ice_height', 'integer', 'Ice plume height in metres',
              widget=Range(1, 500, 1)),
        Field('radius', 'integer', 'Influence radius in metres',
              widget=Range(10, 100000, 10)),
    ],
)

CATEGORY.biome(
    64, 'sulfur_volcano', '#b8a020',
    ('Unlike terrestrial silicate volcanoes, these spew molten sulfur whose color changes '
     'according to the temperature (from yellow to black through blood red)'),
    planet_type='toxic',
)

CATEGORY.biome(
    75, 'mineral_thermal_source', '#50b0a0',
    ('A hydrothermal water basin saturated with dissolved minerals. The cooling of the '
     'water at the surface leads to the formation of travertine terraces or siliceous '
     'frits. The basins are often vividly colored'),
    geom='Point',
    planet_type='mineral',
    terrain_modifier=True,
)

CATEGORY.biome(
    86, 'lava_river', '#cc5000',
    ('An active flow channel transporting molten rock (extrusive magma). Unlike a '
     'stationary lava field, a river is characterized by a defined flow velocity'),
    geom='LineString',
    direction_marker=True,
    planet_type='volcanic',
    terrain_modifier=True,
    fields=[
        Field('width_start', 'double', 'Channel width at start (m)',
              widget=Range(0.2, 2000, 0.2)),
        Field('width_end', 'double', 'Channel width at end (m)',
              widget=Range(0.2, 2000, 0.2)),
        Field('flow_rate', 'double', '(Optional) Water flow rate'),
        *rock_fields(),
    ],
)

CATEGORY.biome(
    88, 'columnar_basalt_vertical', '#3d3d4a',
    ('Composed of prisms of cooled lava and basaltic volcanic columns, these structures '
     'exhibit strict geometric regularity'),
    planet_type='volcanic',
    table_name='columnar_basalt_(vertical)',  # legacy table name, kept for existing planets
)

CATEGORY.biome(
    94, 'lava_dome', '#8a3020',
    'A mass of lava whose high viscosity prevents it from flowing',
    geom='Point',
    planet_type='volcanic',
    terrain_modifier=True,
    fields=[
        Field('radius', 'integer', 'Radius in metres',
              widget=Range(10, 10000, 10)),
    ],
)

CATEGORY.biome(
    96, 'pele_haire', '#8a6a20',
    'Capillary obsidian: wind-borne lava projection in the form of filaments',
    planet_type='volcanic',
)
