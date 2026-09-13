"""
Spatial — 3 biomes.
"""

from ..model import BiomeCategory, Field, Range

CATEGORY = BiomeCategory('spatial')

CATEGORY.biome(
    36, 'crater', '#808070',
    ('Circular structure resulting from a meteorite impact. It consists of a central '
     'depression, a raised rim and a radial ejecta field'),
    geom='Point',
    planet_type='barren',
    terrain_modifier=True,
    fields=[
        Field('radius', 'double', 'Crater radius in metres',
              widget=Range(10, 100000, 10)),
    ],
)

CATEGORY.biome(
    38, 'lunar_ground', '#aaaaaa',
    'Loose dusty surface with heavily cratered bright terrain, lunar regolith covering',
    planet_type='barren',
)

CATEGORY.biome(
    39, 'lunar_pool', '#4a4a5a',
    ('Vast plains of dark basalt occupying giant impact basins. Unlike the highlands, the '
     'lunar seas are smoother and have few large craters'),
    planet_type='barren',
)
