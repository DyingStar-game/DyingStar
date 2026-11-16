// How a hair scatters light: Marschner et al. 2003's three paths through a fibre, in the real-time form of
// Brian Karis, "Physically Based Hair Shading in Unreal" (SIGGRAPH 2016, Physically Based Shading course):
//   R    reflected off the surface: white, shifted towards the root by the scales' tilt;
//   TT   through the hair and out the other side: coloured, bright when the light is behind it (blond
//        hair glows against the sun, dark hair barely);
//   TRT  in, reflected off the far wall, out: the coloured second highlight, shifted towards the tip.
// Each is a product of a profile along the hair (M, a Gaussian in the longitudinal angles), one around it
// (N, in the azimuth), a Fresnel term and the hair's absorption along the path (the colour, raised to the
// path's length in hair widths: a darker hair absorbs more on a longer path).
// Plus the light that has bounced between many hairs: a wrapped diffuse over the volume the hair makes,
// whose colour deepens where little light gets in (light_through).
//
// All vectors in view space, unit length, pointing away from the surface: t along the hair, n the volume's
// normal, v to the eye, l to the light. colour = the hair's linear colour (also its absorption).

const float HAIR_IOR_F0 = 0.0465; // ((1 - 1.55) / (1 + 1.55))^2: a hair's keratin
const float HAIR_SQRT_TAU = 2.5066283;

float hair_fresnel(float cos_theta) {
	float m = 1.0 - clamp(cos_theta, 0.0, 1.0);
	float m2 = m * m;
	return HAIR_IOR_F0 + (1.0 - HAIR_IOR_F0) * m2 * m2 * m;
}

// A unit-area Gaussian of width b (rad) at x.
float hair_gauss(float b, float x) {
	return exp(-0.5 * x * x / (b * b)) / (HAIR_SQRT_TAU * b);
}

// The three highlights (R + TT + TRT), times the light's colour and visibility by the caller.
// roughness 0..1 (the longitudinal width is roughness^2 rad), tilt = the scales' tilt (rad),
// strength scales all three, transmission the TT path alone.
vec3 hair_highlights(vec3 t, vec3 v, vec3 l, vec3 colour, float roughness, float tilt, float strength,
		float transmission) {
	float sin_l = clamp(dot(t, l), -1.0, 1.0);
	float sin_v = clamp(dot(t, v), -1.0, 1.0);
	float cos_d = cos(0.5 * abs(asin(sin_v) - asin(sin_l)));
	cos_d = max(cos_d, 0.05);
	vec3 lp = l - sin_l * t;
	vec3 vp = v - sin_v * t;
	float cos_phi = dot(lp, vp) * inversesqrt(dot(lp, lp) * dot(vp, vp) + 1e-4);
	float cos_half_phi = sqrt(clamp(0.5 + 0.5 * cos_phi, 0.0, 1.0));
	float b = max(roughness * roughness, 0.02);
	float sum_sin = sin_l + sin_v;
	vec3 c = clamp(colour, vec3(0.001), vec3(0.999));
	// R: the surface's white highlight. Its shift grows as the view turns from the light (Karis' fit).
	float sa = sin(-2.0 * tilt);
	float ca = cos(-2.0 * tilt);
	float shift_r = 2.0 * sa * (ca * cos_half_phi * sqrt(max(0.0, 1.0 - sin_v * sin_v)) + sa * sin_v);
	float m_r = hair_gauss(b * sqrt(2.0) * cos_half_phi + 0.001, sum_sin - shift_r);
	float n_r = 0.25 * cos_half_phi;
	float f_r = hair_fresnel(sqrt(clamp(0.5 + 0.5 * dot(v, l), 0.0, 1.0)));
	vec3 spec = vec3(m_r * n_r * f_r);
	// TT: through the hair, towards a light behind it.
	float m_tt = hair_gauss(0.5 * b, sum_sin - tilt);
	float n_prime = 1.19 / cos_d + 0.36 * cos_d;
	float a = 1.0 / n_prime;
	float h = cos_half_phi * (1.0 + a * (0.6 - 0.8 * cos_phi));
	float f_tt = hair_fresnel(cos_d * sqrt(clamp(1.0 - h * h, 0.0, 1.0)));
	vec3 t_tt = pow(c, vec3(0.5 * sqrt(max(0.0, 1.0 - h * h * a * a)) / cos_d));
	float n_tt = exp(-3.65 * cos_phi - 3.98);
	spec += m_tt * n_tt * (1.0 - f_tt) * (1.0 - f_tt) * t_tt * transmission;
	// TRT: the coloured highlight, broader, shifted towards the tip.
	float m_trt = hair_gauss(2.0 * b, sum_sin - 4.0 * tilt);
	float f_trt = hair_fresnel(cos_d * 0.5);
	vec3 t_trt = pow(c, vec3(0.8 / cos_d));
	float n_trt = exp(17.0 * cos_phi - 16.78);
	spec += m_trt * n_trt * (1.0 - f_trt) * (1.0 - f_trt) * f_trt * t_trt;
	return spec * strength;
}

// The light scattered between many hairs, 0..1 (the engine multiplies it by the albedo, and by 1/PI
// through LIGHT_COLOR's PI): wrapped over the volume's normal n, part of it as a lone fibre's Kajiya-Kay
// term (lit from any side but along the hair).
float hair_scatter(vec3 t, vec3 n, vec3 l, float wrap) {
	float volume = clamp((dot(n, l) + wrap) / ((1.0 + wrap) * (1.0 + wrap)), 0.0, 1.0) * (1.0 + wrap);
	float fibre = 1.0 - abs(dot(t, l));
	return mix(volume, fibre, 0.33);
}

// The colour light takes on after travelling through hair: light_through = 1 lit directly, towards 0 deep
// in the volume, where only light that has crossed many hairs arrives -- dimmer and deeper in colour.
// strength 0..1: how much deeper (1 = Karis' whole tint, which turns blond orange in its shade).
vec3 hair_scatter_tint(vec3 colour, float light_through, float strength) {
	float luma = max(dot(colour, vec3(0.2126, 0.7152, 0.0722)), 1e-3);
	return pow(clamp(colour / luma, vec3(0.0), vec3(4.0)), vec3((1.0 - clamp(light_through, 0.0, 1.0)) * strength));
}
