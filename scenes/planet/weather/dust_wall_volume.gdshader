shader_type spatial;
// A dust wall as a volume (WeatherPhenomena): a unit box, as long as the front (x), as tall as the wall (y)
// and as deep as its dust and the haze trailing it (z, the front near +0.5) after the node's scale. Each
// pixel's ray is walked through the box: at every step the dust's density is read (a shape — a bowed,
// wandering front, a crest, two ends, dust thinning out behind into a low tattered tail — eaten away by
// billows of 3D noise) and a few steps are taken toward the sun to know how much dust shades the place.
// That shading is the look: lit crowns, dark folds, the low sun glowing through the thin edges. The sparks
// alight in the wall (DustSparks) glow in the dust round them.
//
// Drawn from the box's back faces with no depth test, so it shows from outside and from inside alike; the
// ray stops at what the scene has already drawn (depth_texture).
render_mode blend_mix, cull_front, depth_test_disabled, depth_draw_never, shadows_disabled, unshaded;

uniform sampler3D billows : repeat_enable, filter_linear;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest, repeat_disable;
// The ground under the box (WallGround): its height over the planet's reference sphere, metres. The dust
// stands on it. The map lies on the ground where it was read, ground_span metres across (along the front,
// along the wall's way); the box has moved ground_shift metres over it since.
uniform sampler2D ground_map : filter_linear, repeat_disable;
uniform vec2 ground_span = vec2(1.0);
uniform vec2 ground_shift = vec2(0.0);
// Steps along the view ray at most, and toward the sun. A step is step_m long (m), longer from far away
// (step_far of the distance to the box) and thin_stride times as long through thin dust and empty air.
uniform int steps = 48;
uniform int sun_steps = 3;
uniform float step_m = 90.0;
uniform float step_far = 0.007;
uniform float thin_stride = 3.0;
// The dust's extinction where it is whole, per metre: a wall is opaque within a few hundred metres.
uniform float extinction = 0.012;
// The noise's tile, as a share of the wall's height (it holds about nine billows a side), and the fine
// billows' size over the large ones'.
uniform float billow_tile = 1.2;
uniform float billow_fine = 0.27;
// The front (set by WeatherPhenomena, which puts the box and the sparks by the same numbers): its two ends
// trail its middle by bow of half its length; it wanders back and forth by wander (wall depths: the short
// lobes, the long ones), in waves wander_m metres to the radian; front_margin wall depths are left ahead
// of it in the box. The wall's head leads its foot by nose (wall depths).
uniform float bow = 0.12;
uniform vec2 wander = vec2(0.3, 0.4);
uniform vec3 wander_m = vec3(800.0, 1900.0, 4300.0);
uniform float front_margin = 0.85;
uniform float nose = 0.14;
// The crest rises and falls along the front in swells this many wall heights long (the long ones, the
// short ones), down to low_crest of the wall's height.
uniform vec2 swell_heights = vec2(3.5, 1.2);
uniform float low_crest = 0.4;
// Behind the front the dust thins out: by e every tail_fall wall depths, down to a tail tail_crest of the
// wall's height and tail_dust of its density, in tatters tatter_heights wall heights across.
uniform float tail_fall = 0.9;
uniform float tail_crest = 0.22;
uniform float tail_dust = 0.03;
uniform float tatter_heights = 5.0;
// The wall's edges soften over this share of its height; the billows eat this far into it.
uniform float edge = 0.22;
uniform float erosion = 1.05;
// The dust rolls: the billows drift this fast (m/s; up, and back from the front).
uniform vec3 roll = vec3(0.0, 5.0, -8.0);
// Light: what the dust gets with no sun on it, the first step toward the sun (m; each next one is twice as
// long), and how much brighter the dust is looking toward the sun (forward scattering).
uniform float ambient = 0.35;
uniform float sun_step_m = 70.0;
uniform float forward = 1.6;
// The sparks alight now (DustSparks): where (metres in the box's frame) and how bright; their colour, how
// much they light the dust and how far round them (m).
uniform vec4 sparks[5];
uniform vec3 spark_colour : source_color = vec3(0.72, 0.84, 1.0);
uniform float spark_power = 0.45;
uniform float spark_reach_m = 140.0;
instance uniform vec3 tint = vec3(0.74, 0.60, 0.42);
instance uniform float strength = 1.0;
instance uniform float light = 1.0;
// Where the sun is, in the wall's own frame.
instance uniform vec3 sun_local = vec3(0.0, 1.0, 0.0);
// The box's size, metres; the height of its bottom over the planet's reference sphere (m); the wall's own
// height (m); the share of the box's depth that is the wall's own dust (the rest is the tail).
instance uniform vec3 size = vec3(8000.0, 1500.0, 3000.0);
instance uniform float bottom_m = 0.0;
instance uniform float wall_tall_m = 1500.0;
instance uniform float body = 0.4;
// How far gone the wall is, 0 (whole) to 1 (thinned out to nothing): its edges soften and the billows eat
// deeper into it.
instance uniform float spent = 0.0;
// How much of the open air the eye is in, 1 outside to 0 under the ground (a cave, a mine): the weather
// does not come in (WeatherPhenomena).
instance uniform float open_air = 1.0;

const int SPARKS = 5;
// The noise is read askew: along any straight line through the wall (its front, above all) the same
// billows never come round again, though the noise itself is a tile.
const mat3 ASKEW = mat3(vec3(0.7071, 0.5657, -0.4243), vec3(-0.7071, 0.5657, -0.4243), vec3(0.0, 0.6, 0.8));
const mat3 ASKEW_FINE = mat3(vec3(0.8, 0.0, 0.6), vec3(-0.36, 0.8, 0.48), vec3(-0.48, -0.6, 0.64));

varying vec3 eye_local;
varying vec3 at_local;

void vertex() {
	at_local = VERTEX;
	eye_local = (inverse(MODELVIEW_MATRIX) * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
}

// The wall's own height, metres.
float tall() {
	return wall_tall_m;
}

// A number between 0 and 1 that wanders along the front (x_m metres along it), in swells about wave_m
// long, never the same twice: the noise read along a slanting line.
float along_front(float x_m, float wave_m, float seed) {
	float t = x_m / (wave_m * 7.0);
	return textureLod(billows, vec3(t * 0.731 + seed, t * 0.317 + seed * 1.7, t * 0.183 + 0.6), 0.0).r;
}

// Where the front's foot stands at a place along it (x_m), metres from the box's middle toward its leading
// face. The same numbers as WeatherPhenomena.wall_front_m.
float front_m(float x_m) {
	float along = x_m / (size.x * 0.5);
	float deep = body * size.z;
	return size.z * 0.5 - deep * front_margin - bow * size.x * 0.5 * along * along
			+ deep * (wander.x * (0.6 * sin(x_m / wander_m.x + 1.3) + 0.4 * sin(x_m / wander_m.y + 4.1))
			+ wander.y * sin(x_m / wander_m.z + 0.7));
}

// The wall's shape at a place of the box (-0.5 to 0.5 each way), no billows yet: how far inside it the place
// is (0 outside, 1 well inside), and how much dust the air holds there (1 in the wall, less behind it).
vec2 shape(vec3 u) {
	float along = u.x * 2.0;
	// Height over the ground under the place, as a share of the wall's own height.
	vec3 m = u * size;
	float ground = textureLod(ground_map, (m.xz + ground_shift) / ground_span + 0.5, 0.0).r;
	float h = ((u.y + 0.5) * size.y + bottom_m - ground) / tall();
	float deep = body * size.z;
	float swell = along_front(m.x, tall() * swell_heights.x, 0.11) * 0.6 + along_front(m.x, tall() * swell_heights.y, 0.53) * 0.4;
	// How far behind the front's foot (m), and what is left of the wall there.
	float behind = front_m(m.x) - m.z;
	float left = exp(-max(behind, 0.0) / (deep * tail_fall));
	// Lumps and gaps kilometres across: the crest is not a roof, and the tail is in tatters.
	float tatter = textureLod(billows, ASKEW_FINE * m / (tall() * tatter_heights) + 0.37, 0.0).r;
	float crest = (1.0 - along * along * along * along) * mix(low_crest, 1.0, smoothstep(0.15, 0.65, swell))
			* mix(tail_crest, 1.0, left) * mix(0.72, 1.0, tatter);
	// The head of the wall leads at a third of its height: an overhanging nose.
	float lead = 1.0 - clamp(abs(h / max(crest, 0.05) - 0.35) * 1.6, 0.0, 1.0);
	float soft = edge * tall() * mix(1.0, 2.5, spent);
	float inside = smoothstep(0.0, soft, behind + deep * nose * lead * lead) * smoothstep(0.0, soft, (crest - h) * tall())
			* smoothstep(0.0, soft * 2.0, (0.5 - abs(u.x)) * size.x) * smoothstep(-0.5, -0.2, u.z - (tatter - 0.5) * 0.3);
	return vec2(inside, max(left, tail_dust * smoothstep(0.2, 0.55, tatter)));
}

// The large billows at a place (metres in the box's frame): 0 in a hollow, 1 in a crown.
float swells(vec3 m) {
	return 1.0 - textureLod(billows, ASKEW * (m - roll * TIME) / (tall() * billow_tile), 0.0).r;
}

// What the billows leave of a shape: they eat the edges, and deeper as the wall thins out.
float eaten(float base, float puff) {
	float bite = erosion * mix(1.0, 1.5, spent);
	return clamp((base - (1.0 - puff) * mix(bite, bite * 0.2, base)) * 2.5, 0.0, 1.0);
}

// The dust's density at a place of the box, 0 to 1, in full detail.
float density(vec3 u) {
	vec2 base = shape(u);
	if (base.x <= 0.001) {
		return 0.0;
	}
	vec3 m = u * size;
	float fine = 1.0 - textureLod(billows, ASKEW_FINE * (m - roll * TIME * 1.6) / (tall() * billow_tile * billow_fine), 0.0).r;
	return eaten(base.x, swells(m) * 0.65 + fine * 0.35) * base.y;
}

// The same, cheaper (large billows only): what shades a place from the sun.
float density_coarse(vec3 u) {
	vec2 base = shape(u);
	return base.x <= 0.001 ? 0.0 : eaten(base.x, swells(u * size)) * base.y;
}

void fragment() {
	// The ray, from the eye to this back face, in the box's own frame: p(t) = eye_local + t * ray, t 0 to 1.
	vec3 ray = at_local - eye_local;
	vec3 inv = 1.0 / ray;
	vec3 t_low = (vec3(-0.5) - eye_local) * inv;
	vec3 t_high = (vec3(0.5) - eye_local) * inv;
	vec3 t_near = min(t_low, t_high);
	float t_in = max(max(t_near.x, max(t_near.y, t_near.z)), 0.0);
	// It stops at the scene: both depths lie along this ray, so their ratio is a share of it.
	float depth = texture(depth_texture, SCREEN_UV).r;
	vec4 scene = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float t_out = min(1.0, (-scene.z / scene.w) / max(-VERTEX.z, 0.001));
	if (t_out <= t_in) {
		discard;
	}
	float ray_m = length(ray * size);
	// One step, as a share of the ray: longer from far away, where a pixel covers more of the wall.
	float stride_m = max(step_m, ray_m * t_in * step_far);
	float span = stride_m / ray_m;
	// Each pixel starts its steps a little differently, and differently every frame: the layers a fixed
	// step would draw turn into a grain the temporal anti-aliasing smooths away.
	vec2 pixel = FRAGCOORD.xy + 5.588238 * float(int(TIME * 60.0) % 64);
	float jitter = fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
	vec3 sun = normalize(sun_local);
	float toward_sun = max(dot(normalize(ray * size), sun), 0.0);
	float glow = 1.0 + forward * toward_sun * toward_sun * toward_sun * toward_sun;
	float thick = extinction * strength;
	float through = 1.0;
	float lit = 0.0;
	float sparked = 0.0;
	float t = t_in + jitter * span;
	for (int i = 0; i < steps; i++) {
		if (t >= t_out) {
			break;
		}
		vec3 u = eye_local + ray * t;
		float d = density(u);
		// Through thin dust and empty air the steps are longer: the dust taken is counted over each one's length.
		float stride = d < 0.03 ? thin_stride : 1.0;
		t += span * stride;
		if (d > 0.002) {
			vec3 m = u * size;
			// How much dust stands between this place and the sun.
			float shade = 0.0;
			float reach = sun_step_m;
			for (int k = 0; k < sun_steps; k++) {
				shade += density_coarse((m + sun * reach * 1.5) / size) * reach;
				reach *= 2.0;
			}
			float sunlit = exp(-shade * thick * 0.6);
			// The sky lights a place less under a billow than on top of one: the folds read even in the shade.
			float sky = mix(0.25, 1.0, exp(-density_coarse((m + vec3(0.0, sun_step_m * 2.5, 0.0)) / size) * 1.5));
			float flash = 0.0;
			for (int k = 0; k < SPARKS; k++) {
				vec3 away = (m - sparks[k].xyz) / spark_reach_m;
				flash += sparks[k].w * exp(-dot(away, away));
			}
			float taken = 1.0 - exp(-d * thick * stride_m * stride);
			lit += through * taken * (ambient * sky + (1.0 - ambient) * sunlit * glow);
			sparked += through * taken * flash;
			through *= 1.0 - taken;
			if (through < 0.01) {
				break;
			}
		}
	}
	float cover = 1.0 - through;
	ALBEDO = (tint * light * lit + spark_colour * sparked * spark_power) / max(cover, 0.001);
	ALPHA = clamp(cover * open_air, 0.0, 1.0);
}
