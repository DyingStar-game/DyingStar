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
