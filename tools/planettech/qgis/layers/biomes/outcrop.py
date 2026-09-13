"""
Outcrop — bedrock exposed at the surface (the "mother rock").
=============================================================

Unlike regolith there is nothing loose here: the terrain surface IS the rock
named by ``rock_type``.
"""

from ..model import BiomeCategory
from ..rocks import rock_fields

CATEGORY = BiomeCategory('outcrop', description="Exposed bedrock", priority=100)

CATEGORY.biome(
    105, 'plateau', '#8a7080',
    'High plateau of bare bedrock with sharp edges, barely touched by erosion.',
    fields=rock_fields(),
)

CATEGORY.biome(
    106, 'volcanic', '#5a4a50',
    'Bedrock brought up and reshaped by volcanism — domes, flows and columns of the host rock.',
    fields=rock_fields(),
)
