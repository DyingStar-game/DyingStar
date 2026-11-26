"""The planet of the open QGIS project, for every script of the DyingStar plugin.

setup_planet_project.py writes the project variables `planet_name` and `planet_radius_m`;
`max_quadtree_depth` and `planet_parent_id` are optional, set by hand. Each exporter used to
read them itself and fall back to another planet ("tarsis_4", R = 6 356 000 m) when they were
missing — an export of the wrong body at the wrong radius, with nothing said. Now a project
without them is refused.
"""
from dataclasses import dataclass

#: PlanetData.max_quadtree_depth when the project does not say (tarsis_4: 13).
DEFAULT_MAX_QUADTREE_DEPTH = 13


class NotAPlanetProject(RuntimeError):
    """The open project has no planet_name / planet_radius_m: not set up by the plugin."""


@dataclass(frozen=True)
class Planet:
    name: str
    #: As written in the project variable (setup writes an integer).
    radius_m: float
    max_quadtree_depth: int
    #: The Horizon parent of the body's props ("_planet_<name>"), "" when unset.
    parent_id: str


def _variable(scope, name):
    value = scope.variable(name)
    if value is None:
        return None
    text = str(value).strip()
    return text if text and text != "NULL" else None


def planet(project=None):
    """The open project's planet; raises NotAPlanetProject when it is not one."""
    from qgis.core import QgsExpressionContextUtils, QgsProject
    project = project or QgsProject.instance()
    scope = QgsExpressionContextUtils.projectScope(project)
    name = _variable(scope, "planet_name")
    radius = _variable(scope, "planet_radius_m")
    if not name or not radius:
        raise NotAPlanetProject(
            "ce projet n'est pas un projet planète (pas de variables planet_name / "
            "planet_radius_m) : ouvre le .qgz de la planète, ou crée-le avec "
            "DyingStar ▸ Projet planète…")
    try:
        radius_m = float(radius)
    except ValueError as exc:
        raise NotAPlanetProject(f"planet_radius_m n'est pas un nombre : {radius!r}") from exc
    depth = _variable(scope, "max_quadtree_depth")
    return Planet(
        name=name,
        radius_m=radius_m,
        max_quadtree_depth=int(depth) if depth else DEFAULT_MAX_QUADTREE_DEPTH,
        parent_id=_variable(scope, "planet_parent_id") or "",
    )
