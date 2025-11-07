shader_type spatial;

render_mode blend_mix, depth_test_disabled, unshaded;

uniform sampler2D SCREEN_TEXTURE: hint_screen_texture;

// Fog color
uniform vec4 fog_color : source_color = vec4(0.4, 0.6, 0.8, 1.0);

// Planet parameters (in meters)
uniform float planet_radius = 2.0e6;        // 2000 km radius
uniform float fog_thickness = 2.0e4;        // Dense fog in lowest 20 km
uniform float atmosphere_height = 5.0e4;    // Fade out by 50 km altitude

// Fog behavior
uniform float fog_density = 1e-4;
uniform float falloff_power = 2.0;

// Optionally tint fog by light direction
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform float light_scatter_strength = 0.2;

void fragment() {
    // Compute world-space position of this fragment
    vec3 world_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;

    // Altitude above the planet surface
    float height = length(world_pos) - planet_radius;

    // Compute fog factor based purely on elevation
    float height_factor = clamp(1.0 - (height / fog_thickness), 0.0, 1.0);

    // Exponential falloff for smoothness
    float fog_factor = pow(height_factor, falloff_power);
    fog_factor = 1.0 - exp(-fog_factor * fog_density * fog_thickness);

    // Optional light scattering tint (slight brightening toward sun)
    float light_factor = clamp(dot(normalize(world_pos), normalize(sun_direction)), 0.0, 1.0);
    vec3 scattering = fog_color.rgb + light_scatter_strength * light_factor;

    // Get the object’s visible color (or texture)
    vec3 base_color = texture(SCREEN_TEXTURE, SCREEN_UV).rgb;

    // Mix fog color based on elevation
    vec3 final_color = mix(base_color, scattering, fog_factor);

    ALBEDO = vec3(height, .0, .0);
}
