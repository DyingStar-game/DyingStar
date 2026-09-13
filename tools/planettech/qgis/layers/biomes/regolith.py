"""
Regolith — the loose cover over bedrock: dust, sand, gravel, cobbles, crystals.
================================================================================

What the ground is MADE OF is the rock (``rock_type`` + ``clarity``, chosen per
zone); the layer only says how fine it is.  Corundum is one value among the
rocks — nothing here is corundum-specific.
"""

from ..model import BiomeCategory
from ..rocks import rock_fields

CATEGORY = BiomeCategory('regolith', description="Loose surface cover, by grain size", priority=200)

CATEGORY.biome(
    100, 'dust', '#cfc9bf',
    'Very fine particles (silt-sized).  Kicks up in storms and under vehicles.',
    fields=rock_fields(),
)

CATEGORY.biome(
    101, 'sand', '#d9c69a',
    'Sand-sized grains of the host rock, forming ripples and dunes.',
    fields=rock_fields(),
)

CATEGORY.biome(
    102, 'gravel', '#b3a58c',
    'Loose angular gravel, a few millimetres to a few centimetres.',
    fields=rock_fields(),
)

CATEGORY.biome(
    103, 'cobble', '#968a78',
    'Fist-sized to boulder-sized fragments of the host rock, scattered on the ground.',
    fields=rock_fields(),
)

CATEGORY.biome(
    104, 'crystal', '#c8bfd6',
    'Ground littered with raw crystals of the host rock, from grains to angular shards.',
    fields=rock_fields(),
)
