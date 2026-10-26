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
// its own cell — that is what lets us test the ONE cell the ray falls in instead of its twenty-seven
// neighbours. Which cells hold a star, where in the cell and how bright: the same draw as ever, so the
// constellations a player learnt (and the system chart's) do not move.
//
// A star is a point source far below one pixel, so it is drawn at the size of a PIXEL, not of an angle:
// a gaussian whose width is [param px], the angle one pixel spans here (fwidth of the direction), a
// little wider for the brightest. Sized as an angle (a core of 2.4e-3 rad and a halo three times that,
// until 2026-10-26) a bright star was a 5-pixel disc in a 15-pixel smear at 1080p, softer still at a
// lower resolution, and a faint one fell between the samples and blinked as the view moved.
//
// px       angle (direction units) one pixel spans along this ray
// density  cells per unit of direction (higher = smaller and more numerous)
// coverage fraction of cells holding a star
// gain     peak brightness
vec3 sf_layer(vec3 dir, float px, float density, float coverage, float gain) {
	vec3 p = dir * density;
	vec3 cell = floor(p);
	vec3 h = sf_hash3(cell);
	if (h.x > coverage) {
		return vec3(0.0);
	}
	// [0.35, 0.65]: centred enough that the point never reaches a cell boundary, which is what lets us
	// test the ONE cell the ray falls in instead of its twenty-seven neighbours.
	vec3 star = vec3(0.35) + 0.3 * sf_hash3(cell + 17.0);
	float d = length((p - cell) - star) / density;  // from the star, in direction units (~radians)
	float rank = h.y * h.y;
	// Steep, as in a real sky where each fainter magnitude holds about three times as many stars: most
	// are dim dust and only a handful are bright. A point star is never larger than a pixel, so its
	// brightness is all the eye has to rank it -- a flat draw made every star read as a bright one.
	float magnitude = gain * (0.06 + 0.94 * rank * rank);
	// About half a pixel: a crisp point, whatever the brightness -- the eye reads a bright star by its
	// light, not by its size, and the frame's glow already spreads the brightest. Not much narrower: a
	// star sitting on a pixel corner would lose most of its light and twinkle as the view turns.
	// Never wider than a tenth of its cell, so a zoomed-out chart does not grow it into the boundary.
	float sigma = min(px * (0.5 + 0.1 * rank), 0.1 / density);
	float point = exp(-0.5 * d * d / (sigma * sigma));
	// Near-white, pulled a little towards amber or blue at the ends of the draw.
	vec3 tint = mix(vec3(1.0, 0.76, 0.52), vec3(0.66, 0.77, 1.0), smoothstep(0.2, 0.8, h.z));
	return mix(vec3(1.0), tint, 0.6) * magnitude * point;
}

// The sky along [param dir]: three layers of stars -- the dust, the middle, and the few that read as
// stars. The faint layers carry the DENSITY of the sky and are well under a pixel as an angle: drawn
// at pixel size (sf_layer) they stay, where shrinking them as an angle deleted them (a pass at
// ~5e-4 rad emptied the sky). Only from a fragment stage: px comes from fwidth.
vec3 sf_starfield(vec3 dir) {
	vec3 d = normalize(dir);
	float px = max(length(fwidth(d)), 1e-6);
	return sf_layer(d, px, 82.0, 0.085, 0.30)
		+ sf_layer(d, px, 43.0, 0.050, 0.55)
		+ sf_layer(d, px, 19.0, 0.028, 1.20);
}
