"""
Aride desert — 11 biomes.
"""

from ..model import BiomeCategory, Field, Range

CATEGORY = BiomeCategory('aride_desert')

CATEGORY.biome(
    5, 'sandy_desert', '#d4a437',
    'A hyperarid region dominated by the accumulation of quartz or silicate grains',
    planet_type='terrestrial',
    name_hint='(Optional) Sandy desert name',
)

CATEGORY.biome(
    6, 'rocky_desert', '#a0744f',
    ('An arid expanse characterized by bare rock slabs and stone plateaus (mesas) sculpted '
     'by erosion'),
    planet_type='terrestrial',
    name_hint='(Optional) Rocky desert name',
)

CATEGORY.biome(
    7, 'salt_desert', '#e8dcc8',
    ('An endorheic depression where evaporation of runoff water leaves behind a crust of '
     'evaporites'),
    planet_type='terrestrial',
    name_hint='(Optional) Salt desert name',
)

CATEGORY.biome(
    42, 'dusty_plain', '#b0a890',
    ('Low-lying area covered with very fine particles (silt, clay). Susceptible to dust '
     'storms'),
    planet_type='barren',
)

CATEGORY.biome(
    54, 'iron_desert', '#c0603a',
    ('A biome whose characteristic red color comes from the oxidation of iron dust. The '
     'atmosphere there is often thin and rich in dust'),
    planet_type='martian',
)

CATEGORY.biome(
    56, 'dry_river_bed', '#8a7a5a',
    ('A former dried-up channel. The soil is composed of rounded pebbles and stratified '
     'sediments'),
    geom='LineString',
    direction_marker=True,
    planet_type='martian',
    terrain_modifier=True,
    fields=[
        Field('width', 'integer', 'Channel width in metres',
              widget=Range(1, 500, 1)),
    ],
)

CATEGORY.biome(
    72, 'metal_plain', '#8a8a9a',
    ('A biome whose surface is composed of native metals (iron, nickel or copper) or '
     'minerals with a metallic luster (pyrite, magnetite)'),
    planet_type='mineral',
)

CATEGORY.biome(
    89, 'anhydrite_desert', '#c8bfb0',
    ('Composed of dehydrated calcium sulfate. These are white or greyish expanses, formed '
     'of hard mineral plates, often resulting from the evaporation of ancient marine '
     'basins'),
    planet_type='terrestrial',
)

CATEGORY.biome(
    90, 'valley_of_fire', '#b85a3a',
    'Ancient sand dune, composed of Aztec sandstone',
    planet_type='terrestrial',
)

