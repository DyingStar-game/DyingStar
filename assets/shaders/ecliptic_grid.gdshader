shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;

// The plane the system's orbits lie in, marked by a small cross at each CROSSING of a grid, rather than by its lines.
//
// Without something there, a chart of inclined orbits is a tangle of curves with no way to tell which
// side of the system a body is on. The plane gives the eye a floor to read heights against, and the
// stalks the chart drops from each body to it do the rest.
//
// The crossings carry the reading: a full mesh at full strength becomes the brightest thing on the
// screen, and the system ends up being read THROUGH the grid. A lattice of marks at a known spacing
// says the same thing for a fraction of the pixels, and the eye completes the lines on its own.
//
// The lines are drawn too, at a tenth of the weight. The eye completes them on its own, but it has to
// be TOLD to — and while it is working out which crossings belong to the same row, the plane is a
// field of marks rather than a surface. A whisper of a mesh answers that before it is asked, without
// ever being what you look at. Which is why it is a separate weight and not a wider cross: the point
// is a continuous line, not more ink at the crossings.
//
// Two lattices rather than one: a fine one for judging small distances and a tenth-as-dense one that
// gives the plane its shape at a glance. They begin and END together, at the distance where the fine
// one stops being resolvable — see the fragment. The spacing is a round number of the moment's scale,
// chosen in GDScript and handed over here.

uniform float grid_step = 1.0;
// Where the chart's floating origin currently is, in the plane. The scene is drawn offset so that what
// the camera watches sits at zero; without adding this back, the lattice would slide along under the
// system instead of staying nailed to it.
uniform vec2 origin_offset = vec2(0.0, 0.0);
// A touch stronger than the dots it replaces: a thinner stroke lays down less ink for the same mark,
// so the same opacity reads fainter.
uniform vec4 line_colour : source_color = vec4(0.45, 0.74, 0.96, 0.72);
uniform float fade_start = 10.0;
uniform float fade_end = 60.0;
uniform float intensity = 1.0;

// Arm half-lengths and stroke width, in PIXELS. In pixels because that is what they have to stay: a
// mark sized in world units is a blob up close and nothing at all at distance, and on a chart spanning
// five orders of magnitude both happen in the same frame.
//
// Long and thin rather than short and thick. A short stroke of any width reads as a dash or a blob and
// says nothing about direction; length is what makes a cross a cross, and the thinner the stroke the
// more length it can carry before the lattice turns back into a mesh.
const float FINE_ARM = 3.6;
const float COARSE_ARM = 7.0;
const float STROKE = 0.7;
// What survives of the fine lattice. It is there to be found when looked for; the coarse one is what
// gives the plane its shape at a glance.
const float FINE_WEIGHT = 0.4;
// And what survives of the continuous lines joining the crossings up. A tenth: any more and the mesh
// takes over from the marks, which is the failure this whole design exists to avoid.
const float MESH_WEIGHT = 0.1;
// How many pixels across a cell should be, at its coarsest. The decade is chosen so that no cell ever
// falls below this on screen, which is what stops the lattice turning into a wash at any distance.
const float CELL_PIXELS = 48.0;

varying vec3 world_pos;


void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}


// How far this pixel is from the nearest lattice line on each axis, IN PIXELS.
//
// Measured through the screen-space derivative, which is what makes every constant above a true pixel
// count at any distance and any angle — on a chart spanning five orders of magnitude, a mark sized in
// world units is a blob up close and nothing at all further out, in the same frame.
vec2 lattice_wave(vec2 coord) {
	return abs(fract(coord - 0.5) - 0.5) / fwidth(coord);
}


// A stroke of the standard width, on a line [param w] pixels away.
float stroke_at(float w) {
	return 1.0 - smoothstep(STROKE - 1.0, STROKE, w);
}


// A small cross at each CROSSING: two short strokes, one along each axis, cut off a few pixels out.
//
// A cross rather than a dot because it says which way the lattice runs. A dot is a position and
// nothing else; a cross carries the two directions with it, so the eye completes the grid from a
// handful of marks instead of guessing at an alignment.
float grid_cross(vec2 wave, float arm) {
	float along_x = stroke_at(wave.y) * (1.0 - smoothstep(arm - 1.0, arm, wave.x));
	float along_y = stroke_at(wave.x) * (1.0 - smoothstep(arm - 1.0, arm, wave.y));

	return max(along_x, along_y);
}


// The same strokes, uncut: the lines themselves, running the whole way between the crossings.
float grid_mesh(vec2 wave) {
	return max(stroke_at(wave.x), stroke_at(wave.y));
}


// How many DECADES coarser than grid_step this pixel needs its lattice to be.
//
// This is what lets the plane be drawn everywhere at once. A single spacing for the whole quad cannot
// work: the plane runs from under the camera to the horizon, so the near field wants one scale and the
// far field wants one a thousand times bigger. Sized for the near field, the far field collapses into
// a wash — every pixel within an arm's length of some crossing, and it looks HEAVIER the further away
// it is, which is precisely backwards. Sized for the far field, there is nothing to read up close.
//
// The chart used to answer that by simply switching the lattice off past the distance where it stopped
// resolving. That gave a definite edge, and it also meant the plane vanished exactly when you leaned in
// — which is when a floor is most worth having.
//
// So the decade is chosen PER PIXEL instead, from how much ground that pixel covers. Every part of the
// plane then carries a lattice sized for where it is: readable up close, readable at the horizon, and
// never a wash anywhere. It is anchored to grid_step's own decades rather than to the pixel, so the
// lines stay on round numbers of the moment's scale and do not swim as the camera moves.
float decade_for(vec2 here, float step) {
	float per_pixel = max(fwidth(here.x), fwidth(here.y));
	// The cell this pixel would like, in world units, then how many decades that is above the base.
	return max(log(max(per_pixel * CELL_PIXELS, 1e-20) / step) / log(10.0), 0.0);
}


void fragment() {
	vec2 here = world_pos.xz + origin_offset;
	// Two neighbouring decades and how far this pixel stands between them. Drawing both and crossing
	// them over is what keeps the change from being a seam: the finer one arrives as the coarser one
	// is still there, the way the numbers on a ruler would if the ruler could re-rule itself.
	float decade = decade_for(here, grid_step);
	float blend = fract(decade);
	float step_near = grid_step * pow(10.0, floor(decade));
	float step_far = step_near * 10.0;

	vec2 near_wave = lattice_wave(here / step_near);
	vec2 far_wave = lattice_wave(here / step_far);
	// The near decade fades OUT as the pixel outgrows it, and the far one is always there — so there is
	// never a moment with nothing drawn, which is the whole requirement.
	float fine = grid_cross(near_wave, FINE_ARM) * FINE_WEIGHT * (1.0 - blend);
	float coarse = grid_cross(far_wave, COARSE_ARM);
	// The mesh rides UNDER the marks rather than adding to them: taken as a maximum, a crossing keeps
	// its own weight instead of gaining a tenth for sitting where two lines meet — which would brighten
	// exactly the pixels that are already the brightest, and thicken every cross by a hair.
	float mesh = max(grid_mesh(near_wave) * (1.0 - blend), grid_mesh(far_wave)) * MESH_WEIGHT;
	float mark = max(max(fine, coarse), mesh);

	float away = length(world_pos - CAMERA_POSITION_WORLD);
	// The plane ENDS, and that is deliberate: a floor with a horizon is a place, one that runs on for
	// ever is a backdrop. The eye takes the edge for the horizon and stops looking past it.
	float by_distance = 1.0 - smoothstep(fade_start, fade_end, away);
	// Only the degenerate case now, and it is worth saying why it shrank so far.
	//
	// It used to bite from a shallow angle, because a lattice sized on one global scale turns to
	// aliasing when seen edge-on. That is no longer possible: the decade is chosen per pixel, so a cell
	// is never smaller than CELL_PIXELS wherever it is drawn. What was left was the damage — the limit
	// where it cut out is a line of constant view angle, and from a camera looking level at a planet
	// that line is dead HORIZONTAL. The plane came to a straight edge across the screen, which reads as
	// a bug and not as a horizon.
	//
	// The far veil is what ends the plane; it is circular, centred under the camera, and it reads as a
	// horizon because it is one. This only removes the last degree or so, where the plane is exactly
	// edge-on and has no area left to draw anyway.
	float by_angle = smoothstep(0.0, 0.02, abs(dot(normalize(VIEW), NORMAL)));

	ALBEDO = line_colour.rgb;
	ALPHA = mark * line_colour.a * by_distance * by_angle * intensity;
}
