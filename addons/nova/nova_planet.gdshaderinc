// The look of a body from afar, shared by the dock's miniature (canvas) and the editor's far sphere
// (spatial): each variant in its palette colour, the selected variant outlined. The miniature also shades
// it by the real relief under a fixed sun and hazes its limb (nova_planet); the far sphere takes only the
// ground and the outline, and is lit like the terrain it continues (nova_far.gdshader).

uniform sampler2D ids : filter_nearest, repeat_enable;  // variant id per longitude/latitude pixel
uniform sampler2D palette : filter_nearest;  // variant id -> colour
uniform sampler2D relief : filter_linear, repeat_enable;  // metres
uniform bool has_relief = false;
uniform float slope_gain = 0.0;  // relief exaggeration / body radius
uniform int selected = 0;

// Longitude/latitude texture coordinates of body direction d (HEALPix.vec2lonlat).
vec2 nova_uv(vec3 d) {
	return vec2(atan(-d.z, d.x) / TAU + 0.5, 0.5 - asin(clamp(d.y, -1.0, 1.0)) / PI);
}

float nova_id_at(vec2 uv) {
	return floor(textureLod(ids, uv, 0.0).r * 255.0 + 0.5);
}

// Variant id of map pixel `texel` (wrapped in longitude, clamped in latitude).
float nova_texel_id(vec2 texel) {
	vec2 size = vec2(textureSize(ids, 0));
	texel.x = mod(texel.x, size.x);
	texel.y = clamp(texel.y, 0.0, size.y - 1.0);
	return floor(texelFetch(ids, ivec2(texel), 0).r * 255.0 + 0.5);
}

vec3 nova_palette(float id) {
	return texelFetch(palette, ivec2(int(id), 0), 0).rgb;
}

// Ground colour at uv, borders kept sharp. Each of the four nearest map pixels counts for its bilinear
// weight; the variant with the most weight wins, and the contour where the two heaviest weigh the same is
// anti-aliased over about one screen pixel. Seen close (a ~10 km map pixel over many screen pixels), plain
// bilinear smeared a border over all of them and nearest drew stair-steps: this follows the bilinear
// contour (the steps chamfered) with a crisp edge. Once a map pixel shrinks under ~1 screen pixel it fades
// back to plain bilinear. Uses screen derivatives: fragment stage, uniform control flow only.
vec3 nova_ground(vec2 uv) {
	vec2 size = vec2(textureSize(ids, 0));
	vec2 at = uv * size - 0.5;
	vec2 f = fract(at);
	vec2 base = floor(at);
	float id[4];
	vec3 col[4];
	for (int i = 0; i < 4; i++) {
		id[i] = nova_texel_id(base + vec2(float(i % 2), float(i / 2)));
		col[i] = nova_palette(id[i]);
	}
	vec4 ids4 = vec4(id[0], id[1], id[2], id[3]);
	vec4 b = vec4((1.0 - f.x) * (1.0 - f.y), f.x * (1.0 - f.y), (1.0 - f.x) * f.y, f.x * f.y);
	vec3 blended = col[0] * b.x + col[1] * b.y + col[2] * b.z + col[3] * b.w;
	// Weight of each corner's variant: its own and that of every corner of the same variant.
	float w[4];
	int best = 0;
	for (int i = 0; i < 4; i++) {
		w[i] = dot(b, vec4(1.0) - step(vec4(0.5), abs(ids4 - id[i])));
		if (w[i] > w[best]) {
			best = i;
		}
	}
	int second = best;
	float ws = 0.0;
	for (int i = 0; i < 4; i++) {
		if (abs(id[i] - id[best]) > 0.5 && w[i] > ws) {
			ws = w[i];
			second = i;
		}
	}
	// 0 on the contour, growing away from it: continuous across it, so its screen width is the edge's.
	float gap = w[best] - ws;
	float edge = clamp(0.5 + gap / max(2.0 * fwidth(gap), 1e-6), 0.0, 1.0);
	vec3 sharp = mix(col[second], col[best], edge);
	// Map pixels per screen pixel; uv jumps by 1 across the longitude seam, unwrap it.
	vec2 ax = dFdx(at);
	vec2 ay = dFdy(at);
	ax.x -= size.x * round(ax.x / size.x);
	ay.x -= size.x * round(ay.x / size.x);
	return mix(sharp, blended, smoothstep(0.35, 1.0, max(length(ax), length(ay))));
}

// Is uv on the selected variant's outline: a neighbour du / dv away (screen derivatives of uv, 1.5 px)
// on the other side.
bool nova_outlined(vec2 uv, vec2 du, vec2 dv) {
	if (selected <= 1 || abs(du.x) >= 0.1 || abs(dv.x) >= 0.1) {
		return false;
	}
	float me = float(int(nova_id_at(uv)) == selected);
	float other = float(int(nova_id_at(uv + du)) == selected) + float(int(nova_id_at(uv - du)) == selected)
			+ float(int(nova_id_at(uv + dv)) == selected) + float(int(nova_id_at(uv - dv)) == selected);
	return abs(other - 4.0 * me) > 0.5;
}

// The ground's normal at body direction d, tilted by the relief's slope towards the east and the north.
vec3 nova_relief_normal(vec3 d, vec2 uv) {
	if (!has_relief) {
		return d;
	}
	float lon = atan(-d.z, d.x);
	vec2 t = 1.0 / vec2(textureSize(relief, 0));
	float east = textureLod(relief, uv + vec2(t.x, 0.0), 0.0).r - textureLod(relief, uv - vec2(t.x, 0.0), 0.0).r;
	float north = textureLod(relief, uv - vec2(0.0, t.y), 0.0).r - textureLod(relief, uv + vec2(0.0, t.y), 0.0).r;
	east *= slope_gain / (2.0 * t.x * TAU * max(sqrt(1.0 - d.y * d.y), 0.05));
	north *= slope_gain / (2.0 * t.y * PI);
	vec3 e = vec3(-sin(lon), 0.0, -cos(lon));
	return normalize(d - east * e - north * cross(d, e));
}

// The miniature's look of body direction d. uv = nova_uv(d), du / dv its screen derivatives (1.5 px), sun
// the light's direction in the body frame, facing the cosine between the ground's normal and the viewer.
vec3 nova_planet(vec3 d, vec2 uv, vec2 du, vec2 dv, vec3 sun, float facing) {
	vec3 c = nova_ground(uv);
	c *= mix(0.5, 1.15, max(dot(nova_relief_normal(d, uv), sun), 0.0));
	if (nova_outlined(uv, du, dv)) {
		c = vec3(1.0);
	}
	// Air: a haze thickening towards the limb.
	return mix(c, vec3(0.62, 0.7, 0.8), pow(1.0 - clamp(facing, 0.0, 1.0), 3.0) * 0.6);
}
