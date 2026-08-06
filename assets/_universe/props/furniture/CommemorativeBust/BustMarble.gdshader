shader_type spatial;

// Paramètres de couleur
uniform vec4 marble_base_color : source_color = vec4(0.95, 0.95, 0.98, 1.0);
uniform vec4 marble_vein_color : source_color = vec4(0.4, 0.4, 0.5, 1.0);

// Paramètres d'échelle et de contrôle
uniform float marble_scale : hint_range(0.1, 20.0) = 1.0;
uniform float vein_intensity : hint_range(0.0, 2.0) = 0.6;
uniform float vein_sharpness : hint_range(0.1, 1.0) = 0.4;
uniform float vein_thickness : hint_range(0.1, 3.0) = 1.0;
uniform float vein_complexity : hint_range(0.5, 3.0) = 1.5;

varying vec3 world_position;

// Fonction de bruit améliorée pour un aspect plus réaliste
float hash(vec3 p) {
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.x + p.y) * p.z);
}

float noise(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    
    return mix(
        mix(mix(hash(i + vec3(0,0,0)), hash(i + vec3(1,0,0)), f.x),
            mix(hash(i + vec3(0,1,0)), hash(i + vec3(1,1,0)), f.x), f.y),
        mix(mix(hash(i + vec3(0,0,1)), hash(i + vec3(1,0,1)), f.x),
            mix(hash(i + vec3(0,1,1)), hash(i + vec3(1,1,1)), f.x), f.y), f.z);
}

// Bruit fractal pour les détails du marbre
float fbm(vec3 p) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    
    for(int i = 0; i < 5; i++) {
        value += amplitude * noise(p * frequency);
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    
    return value;
}

void vertex() {
    world_position = VERTEX;
}

void fragment() {
    // Utilise la position mondiale avec l'échelle paramétrable
    vec3 pos = world_position * marble_scale;
    
    // Crée un champ de déformation pour les veines organiques
    float deform1 = fbm(pos * 0.5) * 2.0;
    float deform2 = fbm(pos * 0.3 + vec3(100.0, 0.0, 50.0)) * 1.5;
    
    // Position déformée pour créer des veines sinueuses
    vec3 deformed_pos = pos + vec3(deform1, deform2, deform1 * 0.5);
    
    // Crée les veines principales avec des lignes déformées
    float vein_line1 = abs(sin(deformed_pos.y * vein_complexity + deform1 * 3.0));
    float vein_line2 = abs(sin(deformed_pos.x * vein_complexity * 0.7 + deform2 * 2.0));
    float vein_line3 = abs(sin((deformed_pos.x + deformed_pos.z) * vein_complexity * 0.5 + deform1 * 4.0));
    
    // Transforme les lignes en veines fines
    vein_line1 = 1.0 - smoothstep(0.0, vein_thickness * 0.1, vein_line1);
    vein_line2 = 1.0 - smoothstep(0.0, vein_thickness * 0.08, vein_line2);
    vein_line3 = 1.0 - smoothstep(0.0, vein_thickness * 0.06, vein_line3);
    
    // Combine les veines avec différentes intensités
    float main_veins = max(vein_line1 * 0.8, max(vein_line2 * 0.6, vein_line3 * 0.4));
    
    // Ajoute des veines secondaires plus fines
    float fine_noise = fbm(pos * 4.0);
    float fine_veins = fbm(pos * 8.0 + vec3(fine_noise * 2.0, 0.0, fine_noise));
    fine_veins = smoothstep(0.6, 0.8, fine_veins) * 0.3;
    
    // Texture de base du marbre
    float base_marble = fbm(pos * 2.0) * 0.2 + 0.8;
    
    // Combine tous les éléments
    float final_veins = main_veins * vein_intensity + fine_veins;
    float marble_pattern = base_marble - final_veins;
    
    // Ajuste le contraste et la netteté
    marble_pattern = smoothstep(vein_sharpness - 0.1, vein_sharpness + 0.1, marble_pattern);
    
    // Mélange les couleurs selon le motif
    vec3 final_color = mix(marble_vein_color.rgb, marble_base_color.rgb, marble_pattern);
    
    ALBEDO = final_color;
    ROUGHNESS = 0.15;
    METALLIC = 0.05;
    SPECULAR = 0.8;
}