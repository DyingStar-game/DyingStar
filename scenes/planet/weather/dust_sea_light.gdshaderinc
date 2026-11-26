// The dust sea's light and fog for what is drawn after the aerial pass and stands in the sea all the same
// (WeatherPhenomena's dust walls and devils): the same numbers as dust_sea.gdshaderinc (DustSea pushes them
// to the renderer, WeatherPhenomena to these materials). Without it a wall in the sea was lit as in full sun
// and seen through the fog that hides everything past 1 km: a white cloud pasted on the overcast (2026-11-25).

// The sea's extinction (1/m; 0 = no sea, nothing changes), its mean top and the ground its light bounces on
// (m over the reference sphere), the star's light as the sea takes it (linear, DustSea.light_colour × the
// sun's energy) and the eye's adaptation under it.
uniform float sea_beta = 0.0;
uniform float sea_top = 3300.0;
uniform float sea_ground = 500.0;
uniform vec3 sea_sun = vec3(1.0);
uniform float sea_gain = 1.0;
// The eye's altitude (m over the reference sphere): the fog along a view is the sea's over the share of the
// view that lies under its top (an eye over the sea sees a devil in a basin through the whole sea).
uniform float sea_eye_alt = 0.0;
// The share of the sea's extinction the fog takes along the view (WeatherPhenomena.SEA_FOG_SHARE): a wall or a
// devil in the sea looms out of the fog from two or three times its visibility (an IMAGE choice: at the
// physical 1, a wall 1.5 km away was gone).
uniform float sea_fog_share = 1.0;
// The sea's palette (DustSea.WHITE, ROCK_TINT) for the dust high in a wall or a devil.
uniform vec3 sea_white = vec3(0.96, 0.95, 0.93);
uniform float sea_rock_tint = 0.3;
// Over the sea, the share of the ground's dust colour in the body of a wall or a devil (DustSea.BODY_GROUND_SHARE).
uniform float body_ground_share = 0.7;
// The hue of the sunlight on the dust out of the sea (WeatherPhenomena: the star's colour through the air at
// the thing's place, brightest channel 1): golden at a low sun, as on the ground beside it.
uniform vec3 sun_tint = vec3(1.0);

// The sea's base (m) and the share of its dust under it (DustSea.BASE_M, BELOW_SHARE).
uniform float sea_base = 500.0;
uniform float sea_below_share = 1.0;

const float SEA_LIGHT_TWO_STREAM = 0.225;


// The sea's optical depth per unit of extinction between heights [param lo] and [param hi] (m): full over
// the base, sea_below_share under it (dust_sea.gdshaderinc sea_depth_between, DustSea.depth_between).
float sea_light_depth(float lo, float hi) {
	return max(hi - max(lo, sea_base), 0.0) + sea_below_share * max(min(hi, sea_base) - lo, 0.0);
}
const float SEA_LIGHT_MS_GAIN = 0.85;
const float SEA_LIGHT_DIRECT_GAIN = 0.45;


// The light on dust at [param alt] m (over the reference sphere): [param above] (the material's own light,
// as in the open) over the sea, the sea's light under it: the star's beam through the sea over the place
// ([param mu]: the sun's height there; [param shade]: the material's own self-shading toward the sun;
// [param glow]: its forward scattering), and the overcast's diffuse light through [param sky] (the
// material's own occlusion of the sky).
vec3 sea_light(float alt, float mu, float shade, float glow, float sky, vec3 above) {
	if (sea_beta <= 0.0) {
		return above;
	}
	float column = sea_beta * sea_light_depth(alt, sea_top);
	float under = smoothstep(0.3, 3.0, column);
	if (under <= 0.0) {
		return above;
	}
	float m = max(mu, 0.0);
	float below = sea_beta * sea_light_depth(sea_ground, alt);
	float multi = m * (1.0 + SEA_LIGHT_TWO_STREAM * below) / (1.0 + SEA_LIGHT_TWO_STREAM * (below + column));
	float direct = exp(-column / max(m, 0.05)) * shade * glow;
	vec3 lit = sea_gain * sea_sun * (SEA_LIGHT_MS_GAIN * multi * sky + SEA_LIGHT_DIRECT_GAIN * direct);
	return mix(above, lit, under);
}


// How much of dust [param distance_m] metres from the eye, at [param alt] m, still shows through the sea:
// the view's stretch under the top (the eye and the dust on a straight line between their two heights).
float sea_fog(float distance_m, float alt) {
	if (sea_beta <= 0.0) {
		return 1.0;
	}
	float low = min(alt, sea_eye_alt);
	float high = max(alt, sea_eye_alt);
	// The view's mean share of the sea's extinction: none over the top, sea_below_share under the base.
	float under = high - low > 1.0 ? clamp(sea_light_depth(low, min(high, sea_top)) / (high - low), 0.0, 1.0)
			: (low < sea_top ? (low < sea_base ? sea_below_share : 1.0) : 0.0);
	return exp(-sea_beta * sea_fog_share * distance_m * under);
}
