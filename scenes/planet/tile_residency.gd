class_name TileResidency
extends RefCounted
## Quelles tuiles d'élévation un chunk exige, et comment les obtenir avant de le construire.
##
## Extrait de [PlanetData] : ces fonctions n'ont pas d'état propre, et le fichier avait
## atteint la limite de lignes du linter.
##
## C'est le point d'accroche de la phase 3 (docs/PLANET_CHUNK_STREAMING.md). Plutôt que de
## propager un état « pending » à travers l'échantillonneur — appelé des milliers de fois
## par chunk depuis WorkerThreadPool — on garantit la résidence AVANT de soumettre la tâche
## de mesh, et on diffère le chunk sinon. La tâche ne rencontre alors jamais de tuile
## manquante, et aucun thread n'attend jamais une socket.

## Tuiles dont la construction d'un chunk a réellement besoin.
##
## Pas seulement la sienne : le noyau bilinéaire de l'échantillonneur déborde d'un texel
## aux extrémités, dans les tuiles voisines (diagonales comprises). Précharger la seule
## tuile centrale laisserait donc des bords se rabattre sur la carte globale.
## La tuile qu'un chunk échantillonne : la sienne quand il est plus grossier que
## nside_max, sinon celle de son ancêtre au niveau d'échantillonnage.
static func chunk_tile(data: PlanetData, hp_nside: int, hp_ipix: int) -> Vector2i:
	var ns := data.sample_nside_for(hp_nside)
	var ip := hp_ipix
	var k := hp_nside
	while k > ns:
		k >>= 1
		ip >>= 2      # parent NESTED
	return Vector2i(ip, ns)


static func chunk_tile_set(data: PlanetData, hp_nside: int, hp_ipix: int) -> Array[Vector2i]:
	var primary := chunk_tile(data, hp_nside, hp_ipix)
	var ns := primary.y
	var ip := primary.x
	var out: Array[Vector2i] = [primary]
	# Une seule fois : get_neighbors_nest refait tout le calcul de face à chaque appel.
	var nbs := HEALPix.get_neighbors_nest(ns, ip)
	for key: String in nbs:
		var nb: int = nbs[key]
		if nb >= 0:
			out.append(Vector2i(nb, ns))
	return out


## The parent-level tiles a stitched chunk's border rows read (see
## PlanetChunk._stitch_edge_heights): the parent's own tile and its eight
## neighbours at the parent's sample level. Empty when the parent reads the
## same tile level as the chunk (nothing more to fetch).
static func stitch_parent_tile_set(data: PlanetData, hp_nside: int, hp_ipix: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if hp_nside < 2:
		return out
	@warning_ignore("integer_division")
	var p_nside: int = hp_nside / 2
	if data.sample_nside_for(p_nside) == data.sample_nside_for(hp_nside):
		return out
	return chunk_tile_set(data, p_nside, hp_ipix >> 2)


## Every tile of [param tiles] readable locally (see tile_available)?
static func tiles_available(data: PlanetData, tiles: Array[Vector2i]) -> bool:
	for t in tiles:
		if not tile_available(data, t.x, t.y):
			return false
	return true


## Une hauteur est-elle disponible localement pour cette tuile, directement ou via un
## ancêtre ? Ne déclenche aucun réseau.
static func tile_available(data: PlanetData, ipix: int, nside: int) -> bool:
	if not data.load_chunk_floats(ipix, nside).is_empty():
		return true
	# Sans source distante, le pack local est l'autorité : ce qu'il n'a pas, il ne l'aura
	# jamais, et sur un pack creux l'ancêtre EST la tuile — l'exportateur ne l'élague que
	# si la reconstruction s'en écarte de moins de SPARSE_EPSILON_M (1 m).
	if data.remote_source == null:
		return data._finest_present_ancestor(ipix, nside).y > 0
	# Avec une source distante, « absente ici » ne dit PAS « absente là-haut », et les deux
	# cas n'ont pas la même garantie :
	#   - réellement élaguée      → l'ancêtre est à moins d'un mètre, par construction ;
	#   - publiée mais pas encore téléchargée → l'ancêtre n'est qu'un parent plus lisse, et
	#     l'écart n'est borné par rien. Mesuré sur tarsis_3 : 35,4 m entre n1024 et son
	#     parent n512 sur une arête franche (les deux tuiles présentes, simple différence
	#     de niveau).
	# Les confondre faisait bâtir la collision sur le parent, puis l'écrire dans le cache
	# disque, où plus rien ne pouvait la distinguer d'une forme correcte : le joueur se
	# retrouvait posé des dizaines de mètres au-dessus du sol qu'il voyait.
	#
	# Et « élaguée » ne suffit pas non plus : la garantie du mètre vaut pour le plus fin
	# ancêtre PUBLIÉ, pas pour le plus fin ancêtre PRÉSENT ICI. Une tuile n1024 élaguée
	# dont le parent n512 est publié mais pas téléchargé remontait jusqu'aux niveaux
	# plancher (n128, texels de 1,6 km) : terrasses de plusieurs centaines de mètres dans
	# le maillage, profils de ligne bâtis sur ce relief-là — différents d'une machine à
	# l'autre selon ce que chacune avait sur disque (client 9 viaducs, serveur 8, même
	# session du 2026-09-14), lits de route 350 m au-dessus du sol. On remonte donc la
	# chaîne de présence : le premier niveau PUBLIÉ rencontré doit être là, sinon on
	# attend ; un niveau inconnu, on attend aussi (request_chunk_tiles met la carte en
	# file).
	return finest_published_ancestor_state(data, ipix, nside) == PUBLISHED_PRESENT


## États de [method finest_published_ancestor_state].
const PUBLISHED_PRESENT := 1   # le plus fin niveau publié de la chaîne est sur disque
const PUBLISHED_ABSENT := 0    # il est publié mais pas encore téléchargé
const PUBLISHED_UNKNOWN := -1  # une carte de présence manque encore
const PUBLISHED_NONE := -2     # rien de publié jusqu'à nside_min : sans espoir


## Remonte la chaîne des ancêtres de (ipix, nside) — le niveau demandé compris — jusqu'au
## premier que le service PUBLIE, et dit s'il est sur disque. Ne déclenche aucun réseau ;
## une carte de présence absente est mise en file par presence_of() et rend
## PUBLISHED_UNKNOWN. Avec [param queue] vrai, la tuile publiée absente est demandée.
static func finest_published_ancestor_state(data: PlanetData, ipix: int, nside: int,
		queue: bool = false) -> int:
	var ns := nside
	var ip := ipix
	while ns >= data.export_nside_min:
		var state: int = data.remote_source.presence_of(ns, ip)
		if state == RemoteTileSource.PRESENCE_UNKNOWN:
			return PUBLISHED_UNKNOWN
		if state == RemoteTileSource.PRESENCE_YES:
			if not data.load_chunk_floats(ip, ns).is_empty():
				return PUBLISHED_PRESENT
			if queue:
				data.remote_source.queue(ns, ip)
			return PUBLISHED_ABSENT
		ns >>= 1
		ip >>= 2
	return PUBLISHED_NONE


## Met en file ce qui manque pour construire ce chunk, et rend true si tout est déjà là.
##
## C'est le point d'accroche qui évite de propager un état « pending » à travers
## l'échantillonneur : PlanetTerrain diffère le chunk tant que ceci rend false, et la
## tâche de mesh ne rencontre jamais de tuile manquante.
## [param with_parent] — the chunk will be STITCHED (PlanetChunk.STITCH_*): its
## border rows read the PARENT pyramid level, so the parent's tile set must be
## resident too. Without it the border fell back to whatever ancestor was on
## disk (the coarse floor levels), hundreds of metres off on a cliff: a wall
## along the chunk edge, 400-1300 m tall, seen from 7-27 km (2026-09-14).
static func request_chunk_tiles(data: PlanetData, hp_nside: int, hp_ipix: int,
		with_parent: bool = false) -> bool:
	if data.remote_source == null:
		return true
	var ready := true
	var unknown := false
	var tiles := chunk_tile_set(data, hp_nside, hp_ipix)
	if with_parent and hp_nside >= 2:
		tiles.append_array(stitch_parent_tile_set(data, hp_nside, hp_ipix))
	for t in tiles:
		if not data.load_chunk_floats(t.x, t.y).is_empty():
			continue
		# Demander la plus fine tuile réellement publiée : sur un pack creux la tuile
		# exacte peut ne pas exister, et c'est son ancêtre qu'il faut rapatrier.
		#
		# presence_of() et NON has_tile() : ce code tourne sur le thread principal, et
		# has_tile va chercher la carte du shard en HTTP synchrone quand elle manque.
		# Appelé pour chaque chunk en attente à chaque frame, cela a fait tomber le jeu
		# à 0,2 FPS. Ici, une carte inconnue met le chunk en attente d'une frame de plus
		# — le fil de téléchargement la rapatrie pendant ce temps.
		var state := finest_published_ancestor_state(data, t.x, t.y, true)
		if state == PUBLISHED_PRESENT:
			continue
		ready = false
		if state == PUBLISHED_UNKNOWN:
			unknown = true
	if PropNet.prof_on:
		if ready:
			PropNet.prof_gate_pass += 1
		else:
			PropNet.prof_gate_defer += 1
			if unknown:
				PropNet.prof_gate_unknown += 1
	return ready


## Met en file les tuiles d'un jeu de chunks, sans décider de leur résidence.
##
## Le garde n'examine que les chunks qu'un créneau de tâche laisse passer — quatre à la
## fois côté serveur. À l'arrivée d'une zone, cela demande les tuiles quatre chunks par
## frame, donc la zone entière au compte-gouttes. Ici on demande TOUT d'un coup, dès que
## le jeu désiré est connu, et le garde trouve ensuite les tuiles déjà là.
##
## Ne compte pas dans les compteurs du garde : ce n'est pas une décision de résidence,
## c'est une anticipation. Rend le nombre de chunks examinés.
static func prefetch_chunks(data: PlanetData, keys: Array) -> int:
	if data == null or data.remote_source == null:
		return 0
	var seen := {}
	var n := 0
	for entry in keys:
		var nside: int = entry.x
		var ipix: int = entry.y
		n += 1
		for t in chunk_tile_set(data, nside, ipix):
			var k := "%d/%d" % [t.y, t.x]
			if seen.has(k):
				continue
			seen[k] = true
			if tile_available(data, t.x, t.y):
				continue
			# Même remontée que le garde : sur un pack creux la tuile exacte peut ne pas
			# exister, et c'est son ancêtre qu'il faut rapatrier. presence_of() ne bloque
			# jamais — ce code tourne sur le thread principal.
			var ns: int = t.y
			var ip: int = t.x
			while ns >= data.export_nside_min:
				var state: int = data.remote_source.presence_of(ns, ip)
				if state == RemoteTileSource.PRESENCE_UNKNOWN:
					break
				if state == RemoteTileSource.PRESENCE_YES:
					data.remote_source.queue(ns, ip)
					break
				ns >>= 1
				ip >>= 2
	return n


## Multiplicateur appliqué au déplacement récent pour viser en avant du joueur. 8 fois la
## course des dernières mises à jour de caméra : assez loin pour couvrir un aller-retour
## réseau, assez près pour ne pas précharger une direction qu'il ne prendra pas.
const PREFETCH_LEAD := 8.0

## Dernier passage de prefetch par planète (clé : id d'instance du PlanetData,
## pour ne pas retenir l'objet) :
## le pixel visé à chaque niveau ne change qu'en franchissant une tuile, et
## refaire les anneaux sans bouger coûtait 9-19 ms toutes les 0,25 s dans le
## pas physique (`terrain_prefetch` du relevé du 2026-09-16) — onze niveaux,
## deux directions, neuf tuiles, deux verrous et un réveil du fil de
## téléchargement par tuile déjà en cache. Le passage est refait quand la
## direction change de pixel au niveau le plus fin, quand une carte de
## présence manquait, ou au plus tard toutes les PREFETCH_REFRESH_MS.
static var _prefetch_memo: Dictionary = {}
const PREFETCH_REFRESH_MS := 5000


## Met en file les tuiles autour du joueur, à tous les niveaux de la pyramide.
##
## Sans cela une tuile n'est demandée qu'au moment où un chunk en a besoin : le chunk est
## alors différé d'au moins un aller-retour, et le joueur voit le terrain apparaître avec
## un temps de retard. Ici on demande AVANT, pendant que le terrain déjà résident s'affiche.
##
## Le travail se fait au niveau des TUILES et non des chunks : évaluer la résidence de
## chaque chunk désiré coûterait une passe sur neuf tuiles et une marche d'ancêtres par
## chunk, pour les centaines de chunks visibles. Une direction donne directement son ipix
## à chaque niveau, et l'anneau de ses huit voisins couvre le déplacement.
##
## [param local_cam] est la position caméra en repère planète, [param cam_history] ses
## positions récentes — dès qu'elles décrivent un déplacement on précharge aussi devant le
## joueur, et c'est ce qui fait arriver le terrain avant qu'on y soit.
## Rend le nombre de tuiles mises en file.
static func prefetch(data: PlanetData, local_cam: Vector3, cam_history: PackedVector3Array) -> int:
	if data == null or data.remote_source == null:
		return 0
	if local_cam.length_squared() <= 0.0:
		return 0
	var src: RemoteTileSource = data.remote_source
	var dirs: Array[Vector3] = [local_cam.normalized()]
	if cam_history.size() >= 2:
		var ahead := local_cam + (cam_history[-1] - cam_history[0]) * PREFETCH_LEAD
		if ahead.length_squared() > 0.0:
			dirs.append(ahead.normalized())
	var stamp := PackedInt64Array()
	for d in dirs:
		stamp.append(HEALPix.vec2pix_nest(data.export_nside, d))
	var now := Time.get_ticks_msec()
	var memo: Dictionary = _prefetch_memo.get(data.get_instance_id(), {})
	if not memo.is_empty() and bool(memo["complete"]) and memo["stamp"] == stamp \
			and now - int(memo["msec"]) < PREFETCH_REFRESH_MS:
		return 0
	var complete := true
	var queued := 0
	var seen := {}
	# export_nside_min vaut 0 tant que le manifeste n'est pas lu, et ns *= 2 y bouclerait
	# indéfiniment.
	var ns: int = maxi(data.export_nside_min, 1)
	while ns <= data.export_nside:
		for d in dirs:
			var centre := HEALPix.vec2pix_nest(ns, d)
			var ring: Array[int] = [centre]
			for nb: int in HEALPix.get_neighbors_nest(ns, centre).values():
				if nb >= 0:
					ring.append(nb)
			for ip in ring:
				var k := "%d/%d" % [ns, ip]
				if seen.has(k):
					continue
				seen[k] = true
				# presence_of ne bloque jamais : un shard inconnu se met en file tout seul
				# et l'anneau sera complété au passage suivant.
				var state := src.presence_of(ns, ip)
				if state == RemoteTileSource.PRESENCE_YES:
					src.queue(ns, ip)
					queued += 1
				elif state == RemoteTileSource.PRESENCE_UNKNOWN:
					complete = false
		ns *= 2
	_prefetch_memo[data.get_instance_id()] = {"stamp": stamp, "complete": complete, "msec": now}
	return queued
