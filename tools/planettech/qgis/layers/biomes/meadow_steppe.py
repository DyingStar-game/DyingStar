"""
Meadow steppe — 8 biomes.
"""

from ..model import BiomeCategory

CATEGORY = BiomeCategory('meadow_steppe')

CATEGORY.biome(
    8, 'meadow', '#7dae52',
    ('A temperate biome dominated by a continuous herbaceous layer and soils rich in '
     'organic matter, favored by regular but insufficient rainfall for the development of '
     'a dense forest cover'),
    planet_type='terrestrial',
    name_hint='(Optional) Meadow zone name',
)

CATEGORY.biome(
    9, 'savanna', '#b8a84a',
    ('A tropical or subtropical ecosystem characterized by a dry grassy carpet dotted with '
     'isolated trees, governed by a marked water seasonality'),
    planet_type='terrestrial',
    name_hint='(Optional) Savanna zone name',
)

CATEGORY.biome(
    10, 'steppe', '#9ca056',
    ('Semi-arid plain covered with short grasses and shrubby plants, forming a transition '
     'zone between meadow and desert'),
    planet_type='terrestrial',
    name_hint='(Optional) Steppe zone name',
)

CATEGORY.biome(
    63, 'sulfur_plain', '#c8c030',
    ('Yellowish expanses reminiscent of the moon Io. The ground is covered in elemental '
     'sulfur and solid sulfur dioxide'),
    planet_type='toxic',
)

CATEGORY.biome(
    67, 'chlorinated_field', '#80c060',
    ('Salt deserts composed of halides (such as sodium or potassium chloride). These '
     'plains are often the result of the complete evaporation of ancient salt seas'),
    planet_type='toxic',
)

CATEGORY.biome(
    77, 'terraformed_grass', '#60c040',
    ('Artificial grassland ecosystem whose parameters have been modified to match a '
     'specific biological standard'),
    planet_type='artificial',
)

CATEGORY.biome(
    82, 'agriculture_land', '#a0c040',
    ('Industrial agricultural production zone. Characterized by a geometric sectorization '
     'of the land'),
    planet_type='artificial',
)

CATEGORY.biome(
    84, 'wasteland_irradiated', '#4a5a3a',
    'Environmental wasteland with high residual radiological contamination',
    planet_type='artificial',
)
