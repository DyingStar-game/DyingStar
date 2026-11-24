@tool
class_name NovaSchema
## Every setting Nova knows, with its type, default, bounds and help text.
##
## A setting is addressed by a flat key ("ground/tile_m", "scatter/s2/density") so a profile file stores
## only the keys it overrides, and two people editing different settings never touch the same line.
## The dock builds its widgets from this table; the runtime reads defaults from it.

## Number of scatter layers each variant has (s1 … sN).
const SCATTER_SLOTS := 6

## Value kinds.
const T_FLOAT := "float"
const T_INT := "int"
const T_BOOL := "bool"
## A resource path to a Texture2D.
const T_TEXTURE := "texture"
## A list of resource paths to meshes or scenes (.glb, .tscn, .res, .mesh).
const T_MESHES := "meshes"

## Ground settings: [key, kind, default, min, max, label, help].
const GROUND := [
	["ground/albedo_texture", T_TEXTURE, "", 0, 0, "Texture d'albédo",
		"Texture de couleur multipliée à la teinte de la roche (rocks.json). Vide = aucune."],
	["ground/normal_texture", T_TEXTURE, "", 0, 0, "Normal map",
		"Normal map du sol (OpenGL, Y vers le haut). Vide = aucune."],
	["ground/orh_texture", T_TEXTURE, "", 0, 0, "Occlusion, rugosité, hauteur",
		"Une image, trois cartes : rouge = occlusion (ombre des creux), vert = rugosité (mat ou brillant, "
		+ "point par point), bleu = hauteur (les creux que la seconde matière remplit). Vide = aucune."],
	["ground/tile_m", T_FLOAT, 8.0, 0.5, 200.0, "Taille d'un motif (m)",
		"Taille au sol d'une répétition de la texture, en mètres. Plus grand = motif plus large."],
	["ground/detail_tile_m", T_FLOAT, 0.0, 0.0, 50.0, "Motif fin de près (m)",
		"Près de la caméra, la même texture relue avec ce motif plus petit : le grain aux pieds du joueur. "
		+ "Le grand motif reste pour la vue lointaine, où un petit se répéterait. 0 = aucun. "
		+ "Les objets posés (roches) utilisent ce motif."],
	["ground/texture_strength", T_FLOAT, 0.8, 0.0, 1.0, "Force de la texture",
		"0 = la teinte de la roche seule ; 1 = la texture module pleinement la teinte."],
	["ground/texture_gain", T_FLOAT, 1.6, 0.0, 4.0, "Gain de la texture",
		"Multiplie la texture avant de l'appliquer : remonte une texture sombre, baisse une claire."],
	["ground/texture_contrast", T_FLOAT, 1.0, 0.0, 3.0, "Contraste de la texture",
		"Écarte chaque point de la texture de sa couleur moyenne (seconde et troisième matières comprises) : "
		+ "au-dessus de 1 les pierres et leurs joints se détachent, même en plein soleil où le relief seul les "
		+ "dessinait ; le sol ne s'éclaircit ni ne s'assombrit dans l'ensemble. 1 = la texture telle quelle."],
	["ground/normal_strength", T_FLOAT, 1.0, 0.0, 4.0, "Force du relief",
		"Intensité de la normal map. 0 = sol lisse sous la lumière."],
	["ground/roughness", T_FLOAT, 0.85, 0.0, 1.0, "Rugosité",
		"0 = sol brillant (reflets nets) ; 1 = sol mat."],
	["ground/transition_m", T_FLOAT, 150.0, 0.0, 600.0, "Largeur des transitions (m)",
		"Distance sur laquelle ce sol se mêle à ses voisins, de part et d'autre de la frontière, et sur "
		+ "laquelle ses rochers débordent chez eux. 0 = au plus net que permet le maillage. "
		+ "Cuit dans le terrain : visible après avoir relancé la vue."],
	["ground/blend_sharpness", T_FLOAT, 2.5, 1.0, 16.0, "Netteté des transitions",
		"Dans la bande de transition : 1 = fondu en voile, 16 = plaques bien découpées de chaque sol."],
	["ground/macro_strength", T_FLOAT, 0.0, 0.0, 1.0, "Variation à grande échelle",
		"Taches plus claires et plus sombres qui cassent l'uniformité vue de loin."],
	["ground/macro_size_m", T_FLOAT, 400.0, 10.0, 5000.0, "Taille des taches (m)",
		"Taille des taches de la variation à grande échelle, en mètres."],
	["ground/hex_tiling", T_BOOL, false, 0, 0, "Tuilage hexagonal",
		"Les textures du sol (les trois matières) sont décalées au hasard dans chaque maille d'un pavage et "
		+ "fondues aux bords, en suivant leur hauteur : plus de répétition visible, sans flou. Remplace "
		+ "l'anti-répétition. Garder un grand motif (15 à 25 m) pour les grandes formes vues de loin et "
		+ "un motif fin de près (3 m) pour le détail aux pieds."],
	["ground/parallax_cm", T_FLOAT, 0.0, 0.0, 40.0, "Relief simulé de près (cm)",
		"Profondeur du relief que la texture simule près de la caméra (parallaxe en escalier, jusqu'à 30 m) : "
		+ "pierres et fissures se masquent quand on bouge. 0 = aucun. Demande l'image occlusion / rugosité / "
		+ "hauteur. Au-delà de 10 cm les objets posés semblent flotter ; la silhouette du sol reste plate."],
	["ground/anti_tiling", T_FLOAT, 0.5, 0.0, 1.0, "Anti-répétition",
		"Mélange une seconde lecture tournée de la texture pour cacher la grille du motif."],
	["ground/layer2_share", T_FLOAT, 0.0, 0.0, 1.0, "Seconde matière : part du sol",
		"Part du sol couverte par la seconde matière (sable, poussière…), par plages. 0 = aucune."],
	["ground/layer2_patch_m", T_FLOAT, 60.0, 2.0, 2000.0, "Seconde matière : taille des plages (m)",
		"Taille des plages de la seconde matière. Elle remplit d'abord les creux de la première."],
	["ground/layer2_albedo", T_TEXTURE, "", 0, 0, "Seconde matière : albédo",
		"Texture de couleur de la seconde matière, teintée comme la première par la roche. Vide = aucune."],
	["ground/layer2_normal", T_TEXTURE, "", 0, 0, "Seconde matière : normal map",
		"Normal map de la seconde matière. Vide = aucune."],
	["ground/layer2_orh", T_TEXTURE, "", 0, 0, "Seconde matière : occlusion, rugosité, hauteur",
		"Même image à trois cartes pour la seconde matière. Vide = aucune."],
	["ground/layer2_tile_m", T_FLOAT, 6.0, 0.5, 200.0, "Seconde matière : taille d'un motif (m)",
		"Taille au sol d'une répétition de la seconde texture."],
	["ground/layer2_gain", T_FLOAT, 1.6, 0.0, 4.0, "Seconde matière : gain",
		"Multiplie la seconde texture : plus clair ou plus sombre que la première."],
	["ground/layer3_share", T_FLOAT, 0.0, 0.0, 1.0, "Troisième matière : part du sol",
		"Part du sol couverte par une troisième matière (graviers, poussière…), par plages, par-dessus les "
		+ "deux premières. 0 = aucune."],
	["ground/layer3_patch_m", T_FLOAT, 15.0, 2.0, 2000.0, "Troisième matière : taille des plages (m)",
		"Taille des plages de la troisième matière."],
	["ground/layer3_albedo", T_TEXTURE, "", 0, 0, "Troisième matière : albédo",
		"Texture de la troisième matière, teintée par la roche comme les autres."],
	["ground/layer3_normal", T_TEXTURE, "", 0, 0, "Troisième matière : normal map",
		"Relief fin de la troisième matière. Vide = celui de la première."],
	["ground/layer3_orh", T_TEXTURE, "", 0, 0, "Troisième matière : occlusion, rugosité, hauteur",
		"Même image à trois cartes pour la troisième matière. Vide = aucune."],
	["ground/layer3_tile_m", T_FLOAT, 4.0, 0.5, 200.0, "Troisième matière : taille d'un motif (m)",
		"Taille au sol d'une répétition de la troisième texture."],
	["ground/layer3_gain", T_FLOAT, 1.6, 0.0, 4.0, "Troisième matière : gain",
		"Multiplie la troisième texture : plus clair ou plus sombre que les autres."],
	["ground/relief_min_m", T_FLOAT, 0.0, -20.0, 0.0, "Relief : creux (m)",
		"Le sol ondule entre ce creux et la bosse ci-dessous (vrai relief : maillage et collision). "
		+ "Aplani sur les routes, nivelé sous les bâtiments. Creux = bosse = 0 : le relief du biome. "
		+ "Pris en compte au rechargement du corps."],
	["ground/relief_max_m", T_FLOAT, 0.0, 0.0, 20.0, "Relief : bosse (m)",
		"Hauteur des bosses au-dessus du sol exporté."],
	["ground/relief_wavelength_m", T_FLOAT, 0.0, 0.0, 2000.0, "Relief : taille des ondulations (m)",
		"Distance d'une bosse à la suivante. 0 = celle du biome. Il faut au moins deux sommets du maillage "
		+ "par demi-ondulation : sur Tarsis 3 (un sommet tous les 25 m au plus fin, "
		+ "50 puis 100 m en s'éloignant), 200 m et plus pour que le relief tienne au loin."],
]

## Scatter settings of ONE layer, keys relative to "scatter/sN/": [key, kind, default, min, max, label, help].
const SCATTER := [
	["enabled", T_BOOL, false, 0, 0, "Activée", "Pose cette couche sur la variante."],
	["meshes", T_MESHES, [], 0, 0, "Objets",
		"Modèles posés (.glb, .tscn, .res). Chaque objet est choisi au hasard (déterministe) par cellule."],
	["cell_m", T_FLOAT, 6.0, 0.5, 500.0, "Espacement (m)",
		"Taille d'une cellule de la grille : au plus un objet par cellule. Arrondi à la grille de la planète."],
	["density", T_FLOAT, 0.3, 0.0, 1.0, "Densité",
		"Probabilité qu'une cellule porte un objet. 1 = une par cellule."],
	["scale_min", T_FLOAT, 0.6, 0.05, 50.0, "Échelle min", "Plus petite échelle tirée."],
	["scale_max", T_FLOAT, 1.4, 0.05, 50.0, "Échelle max", "Plus grande échelle tirée."],
	["sink", T_FLOAT, 0.15, 0.0, 1.0, "Enfoncement",
		"Part de la hauteur de l'objet enfoncée dans le sol, pour qu'il ne flotte pas sur une pente."],
	["align", T_FLOAT, 0.6, 0.0, 1.0, "Alignement sur le sol",
		"0 = droit (vertical de la planète) ; 1 = couché sur la pente du sol."],
	["max_slope_deg", T_FLOAT, 35.0, 0.0, 90.0, "Pente max (°)",
		"Pas d'objet sur une pente plus raide que cet angle."],
	["clump_m", T_FLOAT, 0.0, 0.0, 5000.0, "Taille des amas (m)",
		"0 = semis uniforme. Sinon les objets se regroupent en amas de cette taille, séparés par du sol dégagé."],
	["clump_share", T_FLOAT, 0.35, 0.05, 1.0, "Part du sol en amas",
		"Part du terrain couverte par les amas. Petit = quelques amas isolés ; 1 = partout."],
	["like_ground", T_BOOL, true, 0, 0, "Teinte de la roche",
		"L'objet prend la couleur de la roche de sa zone : un modèle sans texture porte aussi celles du sol, "
		+ "un modèle texturé (roche scannée ou sculptée) garde les siennes. Décoche pour ne rien changer au modèle."],
	["own_texture", T_FLOAT, 1.0, 0.0, 1.0, "Part de la texture du modèle",
		"Le grain fin d'un modèle texturé vient de la texture de roche du sol, posée par position (nette à "
		+ "toute taille). Sa propre couleur ne fait que la moduler : 1 = entièrement (roche scannée), "
		+ "0 = pas du tout (son relief et ses creux restent)."],
	["view_m", T_FLOAT, 0.0, 0.0, 20000.0, "Distance de vue (m)",
		"Au-delà, la couche n'est ni posée ni dessinée. 0 = automatique (120 fois la taille de l'objet). "
		+ "Une valeur courte permet une couche dense de petits débris autour du joueur."],
	["seed", T_INT, 0, 0, 999999, "Graine",
		"Change la disposition sans changer la densité. Même graine = mêmes positions pour tous."],
]


## "scatter/s2/density" from slot 2 and "density".
static func scatter_key(slot: int, field: String) -> String:
	return "scatter/s%d/%s" % [slot, field]


## The schema row of [param key] ([key, kind, default, min, max, label, help]), or [] when unknown.
static func field(key: String) -> Array:
	for f: Array in GROUND:
		if f[0] == key:
			return f
	if key.begins_with("scatter/s"):
		var rest := key.substr(len("scatter/s"))
		var slash := rest.find("/")
		if slash > 0:
			var fname := rest.substr(slash + 1)
			for f: Array in SCATTER:
				if f[0] == fname:
					var row := f.duplicate()
					row[0] = key
					if fname == "seed":
						row[2] = int(rest.substr(0, slash)) * 7919
					return row
	return []


## The default value of [param key] (null when unknown). Arrays come back as copies.
static func default_of(key: String) -> Variant:
	var f := field(key)
	if f.is_empty():
		return null
	var v: Variant = f[2]
	if v is Array:
		return (v as Array).duplicate()
	return v


## [param value] coerced to the kind of [param key] and clamped to its bounds.
static func coerce(key: String, value: Variant) -> Variant:
	var f := field(key)
	if f.is_empty():
		return value
	match f[1]:
		T_FLOAT:
			return clampf(float(value), float(f[3]), float(f[4]))
		T_INT:
			return clampi(int(value), int(f[3]), int(f[4]))
		T_BOOL:
			return bool(value)
		T_TEXTURE:
			return str(value) if value != null else ""
		T_MESHES:
			var out: Array = []
			if value is Array or value is PackedStringArray:
				for p in value:
					if str(p) != "":
						out.append(str(p))
			return out
	return value
