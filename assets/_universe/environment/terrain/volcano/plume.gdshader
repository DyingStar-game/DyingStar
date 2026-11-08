shader_type spatial;
render_mode unshaded, blend_premul_alpha, cull_front, depth_test_disabled, depth_draw_never, shadows_disabled, fog_disabled;

// Plume ray-marched through a pool of puffs (PlumeModel). Everything is in the plume's LOCAL frame, the
// vent at the origin: the camera position comes from a uniform computed in double precision by the
// script, never from a matrix, so it holds at astronomic coordinates.
//
// Each pixel keeps every puff intersecting its ray. Hard candidate caps make overlapping smoke
// switch abruptly between different sets on adjacent pixels, producing polygonal cutouts.
// The march uses long strides with the cheap field until smoke is met, short steps once inside. It is
// thick, so a ray stops within a few short steps: the costly lighting (probes toward the sun and the
// sky) is only paid at the visible surface. That is what draws lit lobes and dark creases.

const int COUNT = 220;

uniform vec4 puff_a[220];
uniform vec4 puff_b[220];
uniform vec4 puff_c[220];
uniform int puff_count = 220;
uniform vec3 cam_local;
uniform vec3 box_center;
uniform vec3 sun_dir;
uniform vec3 sun_color;
uniform vec3 sky_color;
uniform vec3 ground_color;
uniform vec3 haze_color;
uniform float haze_beta = 0.000005;
uniform float sigma = 0.018;
uniform float sim_time = 0.0;
uniform float glow = 1.0;
uniform float multi_scatter = 0.45;
uniform float lava_fill = 0.8;
uniform int max_steps = 140;
// Shortest march step (m): 12 for a volcano's puffs of hundreds of metres, under one for a chimney's.
uniform float min_step = 12.0;
// Height (m) over which the light bounced off the ground fades.
uniform float ground_fade_m = 1500.0;
uniform float erosion = 1.05;
uniform float noise_freq = 0.42;
uniform vec3 ash_dark = vec3(0.075, 0.075, 0.08);
uniform vec3 ash_light = vec3(0.31, 0.30, 0.295);
uniform vec3 ash_warm = vec3(0.30, 0.22, 0.16);
uniform vec3 cloud_tint = vec3(0.55, 0.55, 0.57);
uniform sampler3D billow_tex : repeat_enable, filter_linear;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

varying vec3 v_local;

void vertex() {
	v_local = VERTEX + box_center;
}

float phase_hg(float mu, float g) {
	float gg = g * g;
	return (1.0 - gg) / (12.566 * pow(1.0 + gg - 2.0 * g * mu, 1.5));
}

// Each puff owns its noise: it turns and boils with the puff, never slides through it.
vec3 puff_q(vec3 rel, vec4 pb, vec4 pc) {
	vec3 q = vec3(rel.x * pc.z - rel.z * pc.w, rel.y, rel.x * pc.w + rel.z * pc.z);
	return q * noise_freq + vec3(pb.z, pb.z * 1.7 + sim_time * 0.02, pb.z * 2.3);
}

float carve(float shape, float billow, vec4 pb) {
	// A solid core: the noise only carves the outer shell, so a ray stops on a surface.
	float r = shape * 1.9 - (1.0 - billow) * erosion * (1.0 - smoothstep(0.3, 0.75, shape));
	return smoothstep(0.0, mix(0.05, 0.4, pb.w), r) * pb.x;
}

vec3 puff_relative(vec3 p, vec4 sphere, float cloudiness) {
	vec3 rel = (p - sphere.xyz) / sphere.w;
	rel.y *= 1.0 + 1.5 * cloudiness;
	return rel;
}

// Seven 32-bit masks cover all 220 puffs without large per-pixel index arrays.
int first_bit(uint bits) {
	return int(log2(float(bits & (~bits + 1u))) + 0.5);
}

// One noise fetch per puff: for the search and the light probes.
float field_light(vec3 p, in uint near[7]) {
	float rho = 0.0;
	for (int word = 0; word < 7; word++) {
		uint bits = near[word];
		while (bits != 0u) {
			int i = word * 32 + first_bit(bits);
			bits &= bits - 1u;
			vec4 s = puff_a[i];
			vec3 rel = puff_relative(p, s, puff_b[i].w);
			float d2 = dot(rel, rel);
			if (d2 >= 1.0) {
				continue;
			}
			vec4 pb = puff_b[i];
			float n = textureLod(billow_tex, puff_q(rel, pb, puff_c[i]), 0.0).r;
			rho += carve(1.0 - sqrt(d2), smoothstep(0.18, 0.82, n), pb);
		}
	}
	return rho;
}

void fragment() {
	vec3 ro = cam_local;
	vec3 rd = normalize(v_local - ro);
	float depth = textureLod(depth_tex, SCREEN_UV, 0.0).r;
	float scene_t = 1e12;
	if (depth > 0.0) {
		vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
		scene_t = length(vp.xyz / vp.w);
	}

	uint hits[7];
	for (int word = 0; word < 7; word++) {
		hits[word] = 0u;
	}
	int nh = 0;
	float t0 = 1e20;
	float t1 = -1.0;
	for (int i = 0; i < puff_count; i++) {
		if (puff_b[i].x <= 0.03) {
			continue;
		}
		vec4 s = puff_a[i];
		vec3 oc = ro - s.xyz;
		float bb = dot(oc, rd);
		float h = bb * bb - dot(oc, oc) + s.w * s.w;
		if (h <= 0.0) {
			continue;
		}
		h = sqrt(h);
		float tn = max(-bb - h, 0.0);
		float tf = -bb + h;
		if (tf <= 0.0 || tn >= scene_t) {
			continue;
		}
		// At most COUNT candidates: no replacement or order-dependent truncation.
		hits[i / 32] |= 1u << uint(i % 32);
		nh++;
		t0 = min(t0, tn);
		t1 = max(t1, tf);
	}
	if (nh == 0) {
		discard;
	}
	t1 = min(t1, scene_t);

	float dither = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	// Short step: fine enough for the lobes at this distance, whatever the distance.
	float fine = max(t0 * 0.0022, min_step);
	float coarse = fine * 3.0;
	float t = t0 + coarse * dither;
	bool inside = false;
	int empty = 0;

	float mu = dot(rd, sun_dir);
	float phase = min(mix(phase_hg(mu, 0.55), phase_hg(mu, -0.2), 0.35) * 12.566, 1.9);
	vec3 col = vec3(0.0);
	float trans = 1.0;
	float first_t = -1.0;

	for (int st = 0; st < max_steps; st++) {
		if (t > t1 || trans < 0.04) {
			break;
		}
		vec3 p = ro + rd * t;
		fine = max(t * 0.0022, min_step);
		coarse = fine * 3.0;
		// The puffs this stretch of the ray can touch, the probes' reach included.
		uint near[7];
		for (int word = 0; word < 7; word++) {
			near[word] = 0u;
			uint bits = hits[word];
			while (bits != 0u) {
				int bit = first_bit(bits);
				int i = word * 32 + bit;
				bits &= bits - 1u;
				vec4 sphere = puff_a[i];
				// Conservative interval, including the lighting probes' reach.
				float centre_t = dot(sphere.xyz - ro, rd);
				if (abs(t - centre_t) <= sphere.w * 1.4) {
					near[word] |= 1u << uint(bit);
				}
			}
		}
		if (!inside) {
			if (field_light(p, near) > 0.001) {
				inside = true;
				empty = 0;
				t = max(t - coarse, t0);
			} else {
				t += coarse;
			}
			continue;
		}
		float rho = 0.0;
		float w_sun = 0.0;
		float w_sky = 0.0;
		float w_shade = 0.0;
		float w_cloud = 0.0;
		float w_size = 0.0;
		for (int word = 0; word < 7; word++) {
			uint bits = near[word];
			while (bits != 0u) {
				int i = word * 32 + first_bit(bits);
				bits &= bits - 1u;
				vec4 s = puff_a[i];
				vec3 rel = puff_relative(p, s, puff_b[i].w);
				float d2 = dot(rel, rel);
				if (d2 >= 1.0) {
					continue;
				}
				vec4 pb = puff_b[i];
				vec4 pc = puff_c[i];
				vec3 q = puff_q(rel, pb, pc);
				float n = textureLod(billow_tex, q, 0.0).r;
				float n2 = fine < 90.0 ? textureLod(billow_tex, q * 3.3 + 0.37, 0.0).r : n;
				float billow = smoothstep(0.18, 0.82, n) * 0.72 + smoothstep(0.2, 0.8, n2) * 0.28;
				float r = carve(1.0 - sqrt(d2), billow, pb);
				if (r <= 0.0) {
					continue;
				}
				rho += r;
				w_sun += r * pc.x;
				w_sky += r * pc.y * mix(0.25, 1.0, rel.y * 0.5 + 0.5) * mix(0.15, 1.0, billow);
				w_shade += r * pb.y;
				w_cloud += r * pb.w;
				w_size += r * s.w;
			}
		}
		if (rho <= 0.001) {
			empty++;
			if (empty > 4) {
				inside = false;
			}
			t += fine;
			continue;
		}
		empty = 0;
		float inv = 1.0 / rho;
		float shade = w_shade * inv;
		float cloudy = w_cloud * inv;
		float size = w_size * inv;

		// Broad sun/sky occlusion is already cached per puff by PlumeModel.
		// One local sun probe preserves lobe detail; density estimates local sky attenuation.
		float probe = size * 0.22;
		float toward_sun = field_light(p + sun_dir * probe, near) * probe;
		float sun_t = exp(-toward_sun * sigma * 0.3) * w_sun * inv;
		// A little powder: the very edge of a thick lobe scatters less than just under it.
		sun_t *= mix(1.0, 1.0 - exp(-rho * 3.0), 0.5);
		float sky_t = exp(-rho * sigma * size * 0.16) * w_sky * inv;

		vec3 albedo = mix(ash_dark, ash_light, smoothstep(0.1, 0.9, shade));
		albedo = mix(albedo, ash_warm, 0.45 * smoothstep(0.6, 0.95, shade) * (1.0 - cloudy));
		albedo = mix(albedo, cloud_tint, cloudy);
		vec3 light = sun_color * sun_t * phase + sky_color * mix(0.05, 1.0, sky_t);
		light += sun_color * multi_scatter * mix(0.3, 1.0, sky_t);
		light += ground_color * (1.0 - smoothstep(0.0, ground_fade_m, p.y)) * 0.3;
		light += vec3(1.0, 0.3, 0.07) * glow * exp(-max(p.y, 0.0) / 800.0) * lava_fill;
		vec3 src = albedo * light;
		// The fire under the volcano, lighting the very base of the column.
		src += vec3(1.0, 0.27, 0.05) * glow * exp(-max(p.y, 0.0) / 130.0) * 0.8;

		float stride = fine * mix(5.0, 1.0, clamp(rho * 3.0, 0.0, 1.0));
		float step_t = exp(-rho * sigma * stride);
		col += trans * (1.0 - step_t) * src;
		trans *= step_t;
		if (first_t < 0.0) {
			first_t = t;
		}
		t += stride;
	}
	float alpha = 1.0 - trans;
	if (alpha < 0.002) {
		discard;
	}
	float air = exp(-max(first_t, 0.0) * haze_beta);
	col = col * air + haze_color * (1.0 - air) * alpha;
	ALBEDO = col;
	ALPHA = alpha;
}
