"""
Special — 4 biomes.
"""

from ..model import BiomeCategory, Field

CATEGORY = BiomeCategory('special')

CATEGORY.biome(
    62, 'liquid_hydrocarbon_areas', '#3a5a7a',
    'Surface liquid at extreme pressure/temperature',
    planet_type='atmosphere',
)

CATEGORY.biome(
    68, 'radioactive_waste', '#50a050',
    'Irradiated contaminated zone',
    planet_type='toxic',
)

CATEGORY.biome(
    69, 'tar_basin', '#1a1a1a',
    ('Depressions filled with heavy hydrocarbons (bitumen, asphalt). These basins are '
     'formidable natural traps'),
    planet_type='toxic',
    fields=[
        Field('depth', 'integer', 'Liquid depth in metres'),
    ],
)

CATEGORY.biome(
    70, 'brine_basin', '#4a7a7a',
    ('Submarine or surface lakes with such high salinity that the liquid becomes much '
     'denser than the surrounding water. These areas are often devoid of oxygen'),
    planet_type='toxic',
    fields=[
        Field('surface_depth', 'integer', 'Surface depth in metres'),
        Field('depth', 'integer', 'Liquid depth in metres'),
    ],
)
