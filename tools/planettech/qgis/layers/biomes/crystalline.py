"""
Crystalline — 3 biomes.
"""

from ..model import BiomeCategory

CATEGORY = BiomeCategory('crystalline')

CATEGORY.biome(
    71, 'crystalline_fields', '#a0c0e0',
    ('Areas covered with macro-crystals (quartz, selenite or fluorite). These formations '
     'are generally created in giant hydrothermal cavities whose roof has been eroded, '
     'exposing perfect geometric structures'),
    planet_type='mineral',
)

CATEGORY.biome(
    74, 'quartz_desert', '#d0c8b8',
    ('Arid expanse composed of pure silica grains. Unlike classic silica sand, the surface '
     'has a vitreous and semi-translucent appearance'),
    planet_type='mineral',
)

CATEGORY.biome(
    76, 'salt_crystal_field', '#e0d8c8',
    ('Massive sedimentary deposit of halites. The biome is characterized by natural cubic '
     'formations and hopper-like structures rising from the ground'),
    planet_type='mineral',
)
