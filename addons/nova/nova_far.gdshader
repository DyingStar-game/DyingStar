// The editor's far sphere (NovaFarView): the whole body, drawn only where no real chunk was drawn.
//
// Lit like the far ground it continues (terrain_biome.gdshader past radial_blend_far): the scene's lights
// (in the editor, its preview sun and sky) on the smooth sphere normal, plus the star's light the ground
// emits itself (terrain_far_light.gdshaderinc, far_light_emission). The palette holds each variant's
// ALBEDO as the terrain computes it from afar (NovaDock._far_albedos), not the miniature's tint. No relief
// shading — far chunks shade on the smooth radial — and no haze: in the editor the terrain has no air
// (far_air_scattering is only set on the client), so a haze here was a step at the seam.
shader_type spatial;
render_mode depth_draw_never, depth_test_disabled, cull_back, diffuse_burley, specular_schlick_ggx, shadows_disabled;
#include "res://addons/nova/nova_planet.gdshaderinc"

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
// The terrain material's own far lighting, copied by NovaFarView (same names, same defaults).
uniform vec3 star_dir_world = vec3(0.0, 1.0, 0.0);  // PlanetTerrain._star_dir_world: world UP in the editor
uniform float star_light_energy = 2.0;
uniform vec3 star_light_color : source_color = vec3(1.0, 0.95, 0.85);
uniform float roughness = 0.85;
varying vec3 body_dir;
varying vec3 body_star;

void vertex() {
	body_dir = VERTEX;  // the mesh is a unit sphere in the body frame
	// World to body frame: the basis is a rotation times a uniform scale, so its transpose turns a
	// direction back (scaled, normalised below).
	body_star = transpose(mat3(MODEL_MATRIX)) * star_dir_world;
}

void fragment() {
	vec3 d = normalize(body_dir);
	vec2 uv = nova_uv(d);
	// Everything that takes screen derivatives first, while the whole pixel quad still runs.
	vec2 du = dFdx(uv) * 1.5;
	vec2 dv = dFdy(uv) * 1.5;
	vec3 albedo = nova_ground(uv);
	// Reversed depth: 0 is the far plane, anything above is real geometry in front.
	if (textureLod(depth_texture, SCREEN_UV, 0.0).r > 0.0) {
		discard;
	}
	NORMAL = normalize(mat3(VIEW_MATRIX) * (mat3(MODEL_MATRIX) * d));
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	if (nova_outlined(uv, du, dv)) {
		ALBEDO = vec3(0.0);
		EMISSION = vec3(1.0);
	} else {
		ALBEDO = albedo;
		// far_light_emission without air, blend 1: past radial_blend_far (250 km) every far chunk is there.
		EMISSION = albedo * star_light_color * (max(dot(d, normalize(body_star)), 0.0) * star_light_energy);
	}
}
