"""
Maritime river — 6 biomes.
"""

from ..model import BiomeCategory, Field, Color, Range

CATEGORY = BiomeCategory('maritime_river', priority=300)

CATEGORY.biome(
    0, 'ocean', '#1a5276',
    'A vast expanse of liquid water subject to natural currents',
    planet_type='terrestrial',
    name_hint='(Optional) Ocean name',
    fields=[
        Field('water_color', 'string', '(Optional) Water color override',
              widget=Color()),
    ],
)

CATEGORY.biome(
    2, 'lake', '#3498db',
    'A freshwater or saltwater basin, isolated from ocean currents',
    planet_type='terrestrial',
    name_hint='(Optional) Lake name',
    fields=[
        Field('water_color', 'string', '(Optional) Water color override',
              widget=Color()),
        Field('salinity', 'integer', '(Optional) Salinity percentage 0-100 (default 0)',
              widget=Range(0, 100, 1)),
    ],
)

CATEGORY.biome(
    3, 'delta', '#1a6e5c',
    'Alluvial wetland at the river mouth',
    planet_type='terrestrial',
    name_hint='(Optional) Delta name',
)

CATEGORY.biome(
    4, 'beach', '#f0d9a0',
    'Accumulation of loose sediments (sand, gravel, pebbles) along a coastline',
    planet_type='terrestrial',
    name_hint='(Optional) Beach name',
    fields=[
        Field('beach_color', 'string', '(Optional) Beach color override',
              widget=Color()),
    ],
)

CATEGORY.biome(
    65, 'acid_lake', '#80a030',
    ('Basins filled with a mixture of water and strong acids (sulfuric or hydrochloric), '
     'often located near volcanic areas'),
    planet_type='toxic',
)

CATEGORY.biome(
    85, 'river', '#2471a3',
    ('A permanent watercourse flowing in a defined natural channel, fed by surface or '
     'underground sources, permanently carrying water over a significant distance'),
    geom='LineString',
    direction_marker=True,
    planet_type='terrestrial',
    terrain_modifier=True,
    fields=[
        Field('width_start', 'double', 'Channel width at start (m)',
              widget=Range(0.2, 2000, 0.2)),
        Field('width_end', 'double', 'Channel width at end (m)',
              widget=Range(0.2, 2000, 0.2)),
        Field('flow_rate', 'double', '(Optional) Water flow rate'),
    ],
)
