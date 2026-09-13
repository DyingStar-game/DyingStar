"""
Points of interest: cities, stations, landmarks, spawn points.
"""

from .model import Category, Layer, Field, ValueMap

CATEGORY = Category("poi", None, description="Points of interest (directly under POI)")

POI_TYPES = [
    ("City — populated settlement", "city"),
    ("Station — outpost / base", "station"),
    ("Landmark — notable natural or artificial feature", "landmark"),
    ("Spawn point — player arrival", "spawn_point"),
]

CATEGORY.add(Layer(
    "poi", "Point", (
        Field("name", "string", "Point of Interest name"),
        Field("poi_type", "string", "Type of Point of Interest", widget=ValueMap(POI_TYPES)),
        Field("population", "integer", "Population of the Point of Interest"),
        Field("radius", "double", "Influence radius in metres"),
        Field("elevation", "double", "Ground elevation override"),
        Field("description", "string", "Description of the Point of Interest"),
    ),
    color="#ff4040",
    description="Cities, stations, landmarks, spawn points (read by export_poi.py)",
    symbol={"name": "star", "size": "4"},
))
