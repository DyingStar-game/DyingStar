"""
Forest — 5 biomes.
"""

from ..model import BiomeCategory, Field, Range

CATEGORY = BiomeCategory('forest')

CATEGORY.biome(
    11, 'temperate_forest', '#2d5a1e',
    ('Forest formation composed of deciduous trees or mixed stands, featuring a thick '
     'layer of decomposing litter'),
    planet_type='terrestrial',
    name_hint='(Optional) Forest zone name',
    fields=[
        Field('density', 'double', 'Vegetation density 0.0-1.0',
              widget=Range(0.0, 1.0, 0.01)),
        Field('canopy_height', 'integer', 'Canopy height in metres',
              widget=Range(0, 200, 1)),
    ],
)

CATEGORY.biome(
    12, 'boreal_forest', '#1e4a2a',
    ('A vast belt of conifers adapted to cold climates, with acidic soil and reduced '
     'species biodiversity'),
    planet_type='terrestrial',
    name_hint='(Optional) Forest zone name',
    fields=[
        Field('density', 'double', 'Vegetation density 0.0-1.0',
              widget=Range(0.0, 1.0, 0.01)),
        Field('canopy_height', 'integer', 'Canopy height in metres',
              widget=Range(0, 200, 1)),
    ],
)

CATEGORY.biome(
    13, 'tropical_forest', '#1a5a10',
    ('A high-density vegetation ecosystem characterized by a closed canopy and multiple '
     'vegetation layers. Humidity is saturated'),
    planet_type='terrestrial',
    name_hint='(Optional) Forest zone name',
    fields=[
        Field('density', 'double', 'Vegetation density 0.0-1.0',
              widget=Range(0.0, 1.0, 0.01)),
        Field('canopy_height', 'integer', 'Canopy height in metres',
              widget=Range(0, 200, 1)),
    ],
)

CATEGORY.biome(
    14, 'dead_forest', '#5c4a3a',
    ('Tree stand that has lost its biological viability. The woody structures survive as '
     'charred or mineralized skeletons'),
    planet_type='terrestrial',
    name_hint='(Optional) Forest zone name',
    fields=[
        Field('density', 'double', 'Vegetation density 0.0-1.0',
              widget=Range(0.0, 1.0, 0.01)),
        Field('canopy_height', 'integer', 'Canopy height in metres',
              widget=Range(0, 200, 1)),
    ],
)

CATEGORY.biome(
    78, 'terraformed_forest', '#208020',
    'Artificial planted forest cover on previously treated soil',
    planet_type='artificial',
)
