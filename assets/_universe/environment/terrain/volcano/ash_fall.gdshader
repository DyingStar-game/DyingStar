shader_type particles;
render_mode disable_velocity;

// Ash and lapilli falling around the camera (VolcanoAshVisual). The emitter follows the camera and the
// particles live in its LOCAL frame (world space would be float32 at astronomic coordinates): each frame
// they are moved back by the camera's own motion (cam_delta), so they stay put in the world, and wrapped
// into the box around the camera, so the box never runs empty. They drift with the wind and flutter.

uniform vec3 box_size = vec3(40.0, 30.0, 40.0);
uniform vec3 cam_delta = vec3(0.0);
uniform vec3 wind = vec3(0.0);
uniform float fall_speed = 1.8;
uniform float flutter = 0.5;

uint hash_u(uint x) {
	x = ((x >> 16u) ^ x) * 73244475u;
	x = ((x >> 16u) ^ x) * 73244475u;
	return (x >> 16u) ^ x;
}

float rand01(inout uint seed) {
	seed = hash_u(seed + 0x9E3779B9u);
	return float(seed & 0xFFFFu) / 65535.0;
}

void start() {
	uint seed = hash_u(NUMBER * 747796405u + RANDOM_SEED + INDEX);
	if (RESTART_POSITION) {
		vec3 r = vec3(rand01(seed), rand01(seed), rand01(seed));
		TRANSFORM = mat4(1.0);
		TRANSFORM[3].xyz = (r - 0.5) * box_size;
	}
	// Phase of its flutter, and its build: lapilli bigger and faster than flakes of ash.
	CUSTOM.x = rand01(seed) * 6.2832;
	CUSTOM.y = mix(0.6, 1.6, rand01(seed) * rand01(seed));
	float s = CUSTOM.y;
	TRANSFORM[0].xyz = vec3(s, 0.0, 0.0);
	TRANSFORM[1].xyz = vec3(0.0, s, 0.0);
	TRANSFORM[2].xyz = vec3(0.0, 0.0, s);
}

void process() {
	vec3 p = TRANSFORM[3].xyz - cam_delta;
	float ph = CUSTOM.x + TIME * 1.3;
	vec3 drift = wind + vec3(sin(ph), 0.0, cos(ph * 0.7)) * flutter / CUSTOM.y;
	p += (drift + vec3(0.0, -fall_speed * CUSTOM.y, 0.0)) * DELTA;
	p = mod(p + box_size * 0.5, box_size) - box_size * 0.5;
	TRANSFORM[3].xyz = p;
}
