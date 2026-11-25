shader_type canvas_item;
render_mode unshaded;

// The shock wave of a volcanic blast crossing the view (VolcanoShockBlur): a ring of distortion sweeping
// out from where the blast comes from (origin, in screen UV, possibly off screen), smearing the image a
// little along its way. Full screen, drawn only while a wave passes (a fraction of a second).

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform vec2 origin = vec2(0.5, 0.5);
// Radius of the ring (in screen heights) and its strength (UV offset at its crest).
uniform float radius = 0.0;
uniform float strength = 0.0;
uniform float width = 0.12;

void fragment() {
	vec2 aspect = vec2(SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x, 1.0);
	vec2 d = (SCREEN_UV - origin) * aspect;
	float dist = length(d);
	vec2 dir = dist > 0.0001 ? d / dist : vec2(0.0, 1.0);
	float x = (dist - radius) / width;
	float crest = exp(-x * x);
	// Pushed outward at the crest, a little pulled back behind it: a pressure front.
	vec2 push = dir / aspect * strength * crest * (x > 0.0 ? 1.0 : 0.6);
	vec3 col = vec3(0.0);
	for (int k = 0; k < 4; k++) {
		col += texture(screen_tex, SCREEN_UV - push * (0.5 + float(k) * 0.35)).rgb;
	}
	COLOR = vec4(col * 0.25, 1.0);
}
