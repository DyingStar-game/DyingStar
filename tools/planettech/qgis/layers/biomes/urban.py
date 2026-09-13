"""
Urban — 4 biomes.
"""

from ..model import BiomeCategory

CATEGORY = BiomeCategory('urban')

CATEGORY.biome(
    79, 'mining_excavation', '#5a4a3a',
    ('Open-pit industrial excavation for mineral resource extraction. Features a stepped '
     'topography'),
    planet_type='artificial',
)

CATEGORY.biome(
    80, 'ruins', '#6a6060',
    'Urban or industrial complex in a state of advanced structural degradation',
    planet_type='artificial',
)

CATEGORY.biome(
    81, 'urban', '#707070',
    ('High-density surface of artificial structures and integrated infrastructure. The '
     'natural ground is completely sealed by synthetic or metallic coatings'),
    planet_type='artificial',
)

CATEGORY.biome(
    83, 'landing_pad', '#505050',
    ('Stabilized and reinforced platform designed to withstand the thermal and mechanical '
     'stresses of spacecraft propulsion systems'),
    geom='Point',
    planet_type='artificial',
)
