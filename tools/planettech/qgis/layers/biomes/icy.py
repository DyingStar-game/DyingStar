"""
Icy — 14 biomes.
"""

from ..model import BiomeCategory, Field, Range

CATEGORY = BiomeCategory('icy')

CATEGORY.biome(
    19, 'tundra', '#8fa8b5',
    ('Polar biome defined by the absence of trees and the presence of frozen ground. '
     'Vegetation is limited to mosses, lichens, and dwarf shrubs'),
    planet_type='terrestrial',
)

CATEGORY.biome(
    20, 'snow', '#e8eaed',
    'Permanent blankets of snow ice that increase in density until they become firn ice',
    planet_type='terrestrial',
)

CATEGORY.biome(
    21, 'glacier', '#c8e0f0',
    ('Continental ice mass resulting from the crystallization of snow. Under the effect of '
     'its own weight, the ice behaves like a viscous fluid, flowing and sculpting valleys'),
    planet_type='terrestrial',
)

CATEGORY.biome(
    43, 'ice_plain', '#d0e8f0',
    ('A flat expanse of massive ice. The albedo is very high, resulting in almost total '
     'reflection of stellar radiation'),
    planet_type='cryo',
)

CATEGORY.biome(
    44, 'ice_crevasse', '#90b8d0',
    ('A deep structural rupture within a glacial body or thick ice pack. The walls are '
     'vertical and reveal the stratification of the ice'),
    geom='LineString',
    planet_type='cryo',
    terrain_modifier=True,
)

CATEGORY.biome(
    45, 'ice_pick', '#c0d8e8',
    ('The formation of ice and hardened snow blades or needles. These structures, which '
     'can reach several meters in height, result from a sublimation process of intense '
     'solar radiation in very dry and cold air. They create a sharp, mineral labyrinth'),
    geom='LineString',
    planet_type='cryo',
    terrain_modifier=True,
    fields=[
        Field('height', 'double', 'Formation height in metres',
              widget=Range(0, 100, 0.5)),
    ],
)

CATEGORY.biome(
    46, 'nitrogen_ice', '#e0e8f0',
    ('A plain composed of solidified nitrogen, stable only at extremely low temperatures. '
     'Nitrogen ice behaves in a ductile manner, allowing internal convection currents and '
     'surface regeneration that erases impact craters'),
    planet_type='cryo',
)

CATEGORY.biome(
    47, 'methane_lake', '#2a4a6a',
    ('A liquid basin composed of a mixture of light hydrocarbons, primarily methane and '
     'ethane. Stable under cryogenic pressure and temperature conditions. The liquid has '
     'very low viscosity and surface tension, resulting in extremely slow and faint waves. '
     'Shorelines are sculpted by the erosion of hydrocarbons on a base of rock-hard water '
     'ice'),
    planet_type='cryo',
)

CATEGORY.biome(
    48, 'hydrocarbon_dune', '#5a4a3a',
    'Hydrocarbon sand dunes (Titan)',
    planet_type='cryo',
)

CATEGORY.biome(
    49, 'cryovolcanic', '#b0c8d8',
    ('A geological formation found in cold worlds where magma is replaced by volatiles '
     '(water, ammonia, methane) in a liquid state. Eruptions occur when internal pressure '
     'forces these liquids through the icy crust, solidifying instantly upon contact with '
     'the atmosphere or a vacuum, creating domes of molten ice'),
    planet_type='cryo',
)

CATEGORY.biome(
    50, 'frozen_ocean', '#8ab0c8',
    ('A thick ice pack of water ice overlying a liquid ocean maintained by tidal heating '
     'or thermal insulation'),
    planet_type='cryo',
)

CATEGORY.biome(
    51, 'sublimation_pit', '#c8d8e0',
    ('A rugged terrain formed by the direct transition of CO2 ice from a solid to a '
     'gaseous state under the effect of solar radiation, creating irregular depressions'),
    planet_type='cryo',
)

CATEGORY.biome(
    52, 'permafrost', '#8a9a8a',
    ('Soil whose temperature remains below 0 degrees C for years. Structured soils (frost '
     'polygons) are often found there, resulting from freeze-thaw cycles'),
    planet_type='cryo',
)

CATEGORY.biome(
    97, 'frozen_methane', '#d0dae8',
    'Frozen methane takes the form of soap. This can produce masses of ice',
    planet_type='cryo',
)
