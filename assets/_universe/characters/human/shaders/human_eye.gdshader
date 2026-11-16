// The white of the eye, on the Vitruvian eye: the sclera painted with its veins, and the cornea cut out of
// it -- the black disc at the centre of the map -- so the iris, set back behind it, shows through. The wet
// shine over both is human_eye_wet.gdshader, drawn as this material's next pass.
shader_type spatial;
render_mode depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx, sss_mode_skin;

// Sclera colour; the cornea is its black centre.
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
// Relief of the sclera (tangent-space normal map).
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap, repeat_disable;
// Roughness of the eye's surface under the tear film, 0..1.
uniform float roughness_base : hint_range(0.0, 1.0) = 0.3;
// Scattering in the sclera, 0..1: softens the white so it does not look painted.
uniform float sss_strength : hint_range(0.0, 1.0) = 0.25;
// Shade the lids and lashes cast on the eye, 0..1: how dark the white gets away from the iris.
uniform float lid_shadow : hint_range(0.0, 1.0) = 0.55;
// Whiteness: the painted sclera is pink with veins; this pulls it towards white, 0..1. A real white of the
// eye is warmer than the skin around it is (FFHQ, face_survey/eye_measure.py): little or none.
uniform float whiten : hint_range(0.0, 1.0) = 0.0;
// The socket's shade, 0..1: the brow, the lids and the nose hide most of the sky (and often the sun) from the
// eye, which the engine's shadows and SSAO are too coarse to catch. Measured on 2 582 FFHQ eyes, the lit
// white of the eye is 0.75-1.1 times as bright as the skin under it (not brighter).
uniform float socket_light : hint_range(0.0, 1.0) = 0.33;

void fragment() {
	vec4 texel = texture(albedo_texture, UV);
	float cover = smoothstep(0.02, 0.09, max(texel.r, max(texel.g, texel.b)));
	ALPHA = cover;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	float r = length(UV - vec2(0.5)) * 2.0;
	vec3 white = mix(texel.rgb, vec3(dot(texel.rgb, vec3(0.3333))) * vec3(1.02, 1.0, 0.98), whiten);
	ALBEDO = white * socket_light * mix(1.0, 1.0 - lid_shadow, smoothstep(0.35, 0.95, r));
	NORMAL_MAP = texture(normal_texture, UV).rgb;
	NORMAL_MAP_DEPTH = 0.5;
	ROUGHNESS = roughness_base;
	SPECULAR = 0.25;
	SSS_STRENGTH = sss_strength;
}
