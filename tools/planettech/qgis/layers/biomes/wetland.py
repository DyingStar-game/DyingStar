"""
Wetland — 4 biomes.
"""

from ..model import BiomeCategory

CATEGORY = BiomeCategory('wetland')

CATEGORY.biome(
    16, 'swamp', '#4a6741',
    ('A wooded or grassy wetland where stagnant water permanently saturates the soil. '
     'Characterized by fine sedimentation and high bacterial activity'),
    planet_type='terrestrial',
)

CATEGORY.biome(
    17, 'mangrove', '#3a5a30',
    ('An amphibious coastal forest located in tropical zones. The trees have roots adapted '
     'to high salinity and muddy soil'),
    planet_type='terrestrial',
)

CATEGORY.biome(
    18, 'bog', '#5a6a4a',
    ('A wet, acidic ecosystem that accumulates undecomposed organic matter (peat). Growth '
     'is dominated by sphagnum mosses, creating a spongy soil capable of trapping '
     'significant amounts of carbon'),
    planet_type='terrestrial',
)

CATEGORY.biome(
    66, 'ammonia_swamp', '#6080a0',
    ('Humid areas where the main solvent is not pure water but a water-ammonia mixture. '
     'The ammonia acts as an antifreeze, allowing the liquid to exist at temperatures well '
     'below 0°C'),
    planet_type='toxic',
)
