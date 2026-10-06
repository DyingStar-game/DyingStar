shader_type particles;
// Motion of the ground dust (DustEmitter). Particles are never emitted by the engine on its own: every
// one comes from GPUParticles3D.emit_particle(), which hands over its position, size, velocity and
// colour. A custom process shader rather than a ParticleProcessMaterial because the latter overwrites
// the emitted COLOR with its own, and the colour IS the ground's (measured in Godot 4.7).
//
// The emitter's local frame has +Y as the local up (DustEmitter orients it so), so gravity is simply
// down its Y axis.
//
// CUSTOM: x = spin angle (rad), y = age (s), z = size at birth (m), w = this particle's lifetime (s).
// ground_dust.gdshader reads the same layout through INSTANCE_CUSTOM.

// Downward pull (m/s²): the planet's gravity when airless, a slow settle in air.
uniform float settle = 0.6;
// Air braking (1/s): 0 on an airless body.
uniform float drag = 2.2;
// How much a puff swells (×) by the end of its life.
uniform float growth = 3.0;
// Lifetime spread (0..1) around LIFETIME, so a puff thins out instead of vanishing all at once.
uniform float lifetime_spread = 0.35;

float hash(uint n) {
	n = (n << 13u) ^ n;
	n = n * (n * n * 15731u + 789221u) + 1376312589u;
	return float(n & 0x7fffffffu) / float(0x7fffffff);
}

void start() {
	// emit_particle() has already placed and sized the particle (TRANSFORM) and set its VELOCITY and
	// COLOR before start() runs; the RESTART_* flags are false for what it provided. Do NOT copy
	// EMISSION_TRANSFORM here: that is the EMITTER's frame, and every particle would start at its origin.
	if (RESTART_POSITION) {
		TRANSFORM[3] = vec4(0.0, 0.0, 0.0, 1.0);
	}
	if (RESTART_ROT_SCALE) {
		TRANSFORM[0] = vec4(0.5, 0.0, 0.0, 0.0);
		TRANSFORM[1] = vec4(0.0, 0.5, 0.0, 0.0);
		TRANSFORM[2] = vec4(0.0, 0.0, 0.5, 0.0);
	}
	float r1 = hash(NUMBER * 3u + RANDOM_SEED);
	float r2 = hash(NUMBER * 7u + RANDOM_SEED + 11u);
	CUSTOM = vec4(r1 * 6.2831853, 0.0, length(TRANSFORM[0].xyz),
			LIFETIME * (1.0 + (r2 * 2.0 - 1.0) * lifetime_spread));
}

void process() {
	CUSTOM.y += DELTA;
	if (CUSTOM.y >= CUSTOM.w) {
		ACTIVE = false;
	}
	VELOCITY.y -= settle * DELTA;
	VELOCITY *= max(0.0, 1.0 - drag * DELTA);
	TRANSFORM[3].xyz += VELOCITY * DELTA;
	// Swells fast at first, then slower, the way a puff mixes into the air.
	float t = clamp(CUSTOM.y / max(CUSTOM.w, 0.001), 0.0, 1.0);
	float s = CUSTOM.z * mix(1.0, growth, sqrt(t));
	TRANSFORM[0].xyz = vec3(s, 0.0, 0.0);
	TRANSFORM[1].xyz = vec3(0.0, s, 0.0);
	TRANSFORM[2].xyz = vec3(0.0, 0.0, s);
	CUSTOM.x += DELTA * 0.4;  // a slow turn, so the noise of a hanging puff does not look frozen
}
