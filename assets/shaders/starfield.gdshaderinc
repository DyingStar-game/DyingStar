// Procedural starfield, shared so there is exactly one sky in the game.
//
// Everything here is a pure function of a view DIRECTION, never of a screen position, so the same
// stars come out whatever projects them: the system chart rebuilds a ray per pixel from its camera,
// and a sky shader would hand over its EYEDIR. No texture, no memory, no resolution to outgrow.

// Three independent pseudo-random values in [0,1) for a cell.
vec3 sf_hash3(vec3 cell) {
	vec3 p = vec3(
		dot(cell, vec3(127.1, 311.7, 74.7)),
		dot(cell, vec3(269.5, 183.3, 246.1)),
		dot(cell, vec3(113.5, 271.9, 124.6))
	);
	return fract(sin(p) * 43758.5453123);
}

// One layer of stars.
//
// Direction space is cut into cells; a fraction of them hold a star. The star is kept well inside
// its own cell, halo included — that is what lets us test the ONE cell the ray falls in instead of
// its twenty-seven neighbours, and it is why the halo radius is bounded below.
//
// density  cells per unit of direction (higher = smaller and more numerous)
// coverage fraction of cells holding a star
// radius   angular size of the core, in cell units (the angle is radius / density)
// gain     peak brightness
vec3 sf_layer(vec3 dir, float density, float coverage, float radius, float gain) {
	vec3 p = dir * density;
	vec3 cell = floor(p);
	vec3 h = sf_hash3(cell);
	if (h.x > coverage) {
		return vec3(0.0);
	}
	// [0.35, 0.65]: centred enough that core and halo never reach a cell boundary, which is what lets us
	// test the ONE cell the ray falls in instead of its twenty-seven neighbours.
	vec3 star = vec3(0.35) + 0.3 * sf_hash3(cell + 17.0);
	float d = length((p - cell) - star);
	float core = 1.0 - smoothstep(0.0, radius, d);
	float halo = 1.0 - smoothstep(0.0, radius * 3.0, d);
	// Squared, so the sky is mostly faint dust with a few bright ones carrying the picture.
	float magnitude = gain * (0.2 + 0.8 * h.y * h.y);
	// Near-white, pulled a little towards amber or blue at the ends of the draw.
	vec3 tint = mix(vec3(1.0, 0.76, 0.52), vec3(0.66, 0.77, 1.0), smoothstep(0.2, 0.8, h.z));
	return mix(vec3(1.0), tint, 0.6) * magnitude * (core + 0.16 * halo);
}

// The sky along [param dir]. Three layers: the dust, the middle, and the few that read as stars.
//
// ⚠️ The two faint layers carry the DENSITY of the sky — they are most of what you see, and they are
// already sub-pixel (0.055/82 = 6.7e-4 rad). Shrinking them does not make them finer, it deletes them:
// a shader samples once per pixel, so a filled shape well under a pixel falls between the samples. A
// pass that took all three down to ~5e-4 rad emptied the sky completely. Only the BRIGHT layer was ever
// too big, at 4.5e-3 rad — twenty times a faint one, which is what read as blobs rather than stars.
vec3 sf_starfield(vec3 dir) {
	vec3 d = normalize(dir);
	return sf_layer(d, 82.0, 0.085, 0.055, 0.50)
		+ sf_layer(d, 43.0, 0.050, 0.062, 0.80)
		+ sf_layer(d, 19.0, 0.028, 0.045, 1.20);
}
