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
## Pas seulement la sienne : l'échantillonneur mélange avec les tuiles voisines dans une
## marge de BLEND_PIXELS autour de chaque bord, et le noyau bilinéaire déborde d'un texel
## aux extrémités. Précharger la seule tuile centrale laisserait donc des bords se
## rabattre sur la carte globale.
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


## Une hauteur est-elle disponible localement pour cette tuile, directement ou via un
## ancêtre ? Ne déclenche aucun réseau.
static func tile_available(data: PlanetData, ipix: int, nside: int) -> bool:
	if not data.load_chunk_floats(ipix, nside).is_empty():
		return true
	return data._finest_present_ancestor(ipix, nside).y > 0


## Met en file ce qui manque pour construire ce chunk, et rend true si tout est déjà là.
##
## C'est le point d'accroche qui évite de propager un état « pending » à travers
## l'échantillonneur : PlanetTerrain diffère le chunk tant que ceci rend false, et la
## tâche de mesh ne rencontre jamais de tuile manquante.
static func request_chunk_tiles(data: PlanetData, hp_nside: int, hp_ipix: int) -> bool:
	if data.remote_source == null:
		return true
	var ready := true
	var unknown := false
	for t in chunk_tile_set(data, hp_nside, hp_ipix):
		if tile_available(data, t.x, t.y):
			continue
		ready = false
		# Demander la plus fine tuile réellement publiée : sur un pack creux la tuile
		# exacte peut ne pas exister, et c'est son ancêtre qu'il faut rapatrier.
		#
		# presence_of() et NON has_tile() : ce code tourne sur le thread principal, et
		# has_tile va chercher la carte du shard en HTTP synchrone quand elle manque.
		# Appelé pour chaque chunk en attente à chaque frame, cela a fait tomber le jeu
		# à 0,2 FPS. Ici, une carte inconnue met le chunk en attente d'une frame de plus
		# — le fil de téléchargement la rapatrie pendant ce temps.
		var ns := t.y
		var ip := t.x
		while ns >= data.export_nside_min:
			var state: int = data.remote_source.presence_of(ns, ip)
			if state == RemoteTileSource.PRESENCE_UNKNOWN:
				unknown = true
				break
			if state == RemoteTileSource.PRESENCE_YES:
				data.remote_source.queue(ns, ip)
				break
			ns >>= 1
			ip >>= 2
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
				if src.presence_of(ns, ip) == RemoteTileSource.PRESENCE_YES:
					src.queue(ns, ip)
					queued += 1
		ns *= 2
	return queued
