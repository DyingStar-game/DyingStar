shader_type spatial;
// cull_disabled (matches rocky_ground.gdshader): HEALPix terrain + skirt geometry
// can appear back-facing to the camera, so cull_back would punch black holes in the
// surface and leave only skirts visible. Double-sided rendering avoids that.
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// Far lighting — the star's own light, the smooth radial normal, the far air — and the per-chunk
// instance uniforms, shared with every other ground material (see the include). Past radial_blend_far
// the shading normal is also bent fully onto the smooth planet radial: coarse far chunks light on
// their GEOMETRIC vertex normals, which wander and warp the terminator into a wavy 'yin-yang'.
#include "res://assets/_universe/environment/terrain/terrain_far_light.gdshaderinc"

// A Nova body's ground (NovaBody.build_material): terrain_biome.gdshader with Nova's palette compiled in.
#define NOVA
#include "res://assets/_universe/environment/terrain/terrain_biome.gdshaderinc"
