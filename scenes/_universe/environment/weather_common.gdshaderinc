// The weather's shared shader parts, included ONCE by aerial_perspective.gdshader before the layers
// that use them (today dust_layer.gdshaderinc): the noise textures, the light on the dust and how a
// grain of it is lit. One medium, one light: every dust drawn here is lit the same way.

// A smooth 3D noise (three octaves, NOISE_CELLS features a period), seamless (WeatherSky._make_noise).
// No mipmaps: a feature smaller than what a step or a pixel can see is faded to its mean by the readers.
uniform sampler3D dust_noise : filter_linear_mipmap, repeat_enable;
// The light on the dust in scene units (DustLight): the sun's beam as it arrives (dimmed by the dust
// over the eye), the beam before that dust took its share (the multiple scattering inside a volume is
// computed from it), the ambient term, the sun's direction (world) and the local up (world).
uniform vec3 dust_sun = vec3(1.0);
uniform vec3 dust_sun_free = vec3(1.0);
uniform vec3 dust_ambient = vec3(0.2);
uniform vec3 dust_sun_dir = vec3(0.0, 1.0, 0.0);
uniform vec3 dust_up = vec3(0.0, 1.0, 0.0);


// The dust's phase around the sun for a view [param cos_sun] from it: a forward glow (grains far larger
// than the wavelength scatter forward: the silver lining toward the sun) over a flat base, scaled so a
// sunlit top reads about as bright as a white ground in the engine's units.
float dust_phase(float cos_sun) {
	return 0.3 * (1.0 + 1.6 * pow(max(cos_sun, 0.0), 6.0));
}


// What a grain of dust of colour [param albedo] sends toward the eye: the sun's beam, [param sun_t] of
// it left after the dust in the way, with the [param phase] of the view; plus what the dust around gives
// back ([param diffuse]: the two-stream estimate of what the column overhead lets through beyond the
// direct beam, DustLight) and the ambient, both through the [param crease] of the surface (the hollows
// between billows see less sky). Lit by the dimmed beam alone, a cloud's inside read black (2026-10-08).
vec3 dust_lit_with(vec3 albedo, float phase, float sun_t, float diffuse, float crease, vec3 sun,
		vec3 sun_free, vec3 ambient) {
	return albedo * (sun * phase * sun_t + (sun_free * 0.3 * diffuse + ambient) * crease);
}


// The same under the light at the eye (the near dust: a few hundred metres, the eye's own sky).
vec3 dust_lit(vec3 albedo, float phase, float sun_t, float diffuse, float crease) {
	return dust_lit_with(albedo, phase, sun_t, diffuse, crease, dust_sun, dust_sun_free, dust_ambient);
}


// A per-pixel jitter in [0, 1) (interleaved gradient noise): the steps' edges dither into grain
// instead of banding.
float dust_jitter(vec2 pixel) {
	return fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
}
