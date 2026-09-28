"""
Volcanic geothermal — 12 biomes (volcanoes, lava flows and fumaroles: layers/volcanoes.py).
"""

from ..model import BiomeCategory, Field, Range
from ..rocks import rock_fields

CATEGORY = BiomeCategory('volcanic_geothermal')

# Biome indices 26 (active_volcano), 30 (fumarole), 86 (lava_river),
# 94 (lava_dome) and 107 (fumarole_field) are RESERVED: those layers moved to
# layers/volcanoes.py (procedural, not biomes — the rock under them stays the
# ground's).  Never reuse the indices.

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
    88, 'columnar_basalt_vertical', '#3d3d4a',
    ('Composed of prisms of cooled lava and basaltic volcanic columns, these structures '
     'exhibit strict geometric regularity'),
    planet_type='volcanic',
    table_name='columnar_basalt_(vertical)',  # legacy table name, kept for existing planets
)

CATEGORY.biome(
    96, 'pele_haire', '#8a6a20',
    'Capillary obsidian: wind-borne lava projection in the form of filaments',
    planet_type='volcanic',
)
