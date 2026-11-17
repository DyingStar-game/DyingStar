// The least shader with subsurface scattering. Warmup draws it once, alone, before a person's shaders: the
// first SSS material of a viewport also sets up the engine's SSS effect and its separate specular passes,
// and that is paid in a frame of its own.
shader_type spatial;
render_mode sss_mode_skin;

void fragment() {
	SSS_STRENGTH = 0.5;
}
