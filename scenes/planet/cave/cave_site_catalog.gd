@tool
class_name CaveSiteCatalog
extends Resource
## Runtime content only: exported planetary sites, independent of the authoring interface.

## Planetary cave definitions shipped to the game; each site stores its position, seed and profile.
@export var sites: Array[CavePlacement] = []
