// The iris, on the Vitruvian eye: a disc set back behind the cornea (real geometry: the parallax is free).
// The map is one painted iris; a person's eye colour recolours it, its fibres kept as shading.
shader_type spatial;
render_mode depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// The iris' fibres (colour map; its luminance is what is kept).
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
// Relief of the fibres (tangent-space normal map).
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap, repeat_disable;
// Mean linear luminance of the map's iris ring: a texel at it shows the eye colour as chosen.
uniform float fibre_luminance : hint_range(0.001, 1.0) = 0.07;
// Darkening of the iris' outer rim (the limbal ring), 0..1.
uniform float limbal_ring : hint_range(0.0, 1.0) = 0.7;
// Brightness of the iris against the chosen colour: it sits in the socket's shade (see human_eye.gdshader
// socket_light). Measured on 2 582 FFHQ eyes, an iris is ~0.1 times as bright as the skin under the eye.
uniform float brightness : hint_range(0.0, 4.0) = 0.45;

// ── Per avatar (HumanAppearance) ────────────────────────────────────────────────────────────────────
// Linear eye colour. Index 10: the characters own 8..10 (see human_skin.gdshader).
instance uniform vec3 eye_colour : instance_index(10) = vec3(0.2, 0.1, 0.04);

void fragment() {
	vec3 fibres = texture(albedo_texture, UV).rgb;
	float shade = clamp(dot(fibres, vec3(0.2126, 0.7152, 0.0722)) / fibre_luminance, 0.0, 3.0);
	float r = length(UV - vec2(0.5)) * 2.0;
	ALBEDO = eye_colour * shade * brightness * mix(1.0, 1.0 - limbal_ring, smoothstep(0.72, 0.98, r));
	NORMAL_MAP = texture(normal_texture, UV).rgb;
	ROUGHNESS = 0.45;
	SPECULAR = 0.3;
}
