// The dock's miniature: the body as a disc, turned by `view`.
shader_type canvas_item;
#include "res://addons/nova/nova_planet.gdshaderinc"

uniform mat3 view;  // columns: right, up, towards the viewer (body frame)
uniform vec2 scale;  // control size / disc radius
// A picture laid over the body, longitude/latitude like `ids` (the weather map), and how much of it shows.
uniform sampler2D overlay : filter_linear, repeat_enable;
uniform float overlay_mix = 0.0;

void fragment() {
	vec2 p = (UV - 0.5) * scale;
	p.y = -p.y;
	float r = length(p);
	float z = sqrt(max(1.0 - r * r, 0.0));
	vec3 d = view * vec3(p, z);
	vec2 uv = nova_uv(d);
	// A sun over the viewer's left shoulder, whichever way the planet is turned.
	vec3 c = nova_planet(d, uv, dFdx(uv) * 1.5, dFdy(uv) * 1.5, view * normalize(vec3(-0.45, 0.5, 0.74)), z);
	c = mix(c, texture(overlay, uv).rgb, overlay_mix);
	COLOR = vec4(c, 1.0 - smoothstep(1.0 - fwidth(r) * 1.5, 1.0, r));
}
