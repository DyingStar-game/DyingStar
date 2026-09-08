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
static func chunk_tile_set(data: PlanetData, hp_nside: int, hp_ipix: int) -> Array[Vector2i]:
	var ns := data.sample_nside_for(hp_nside)
	var ip := hp_ipix
	var k := hp_nside
	while k > ns:
		k >>= 1
		ip >>= 2
	var out: Array[Vector2i] = [Vector2i(ip, ns)]
	for key: String in HEALPix.get_neighbors_nest(ns, ip):
		var nb: int = HEALPix.get_neighbors_nest(ns, ip)[key]
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
	for t in chunk_tile_set(data, hp_nside, hp_ipix):
		if tile_available(data, t.x, t.y):
			continue
		ready = false
		# Demander la plus fine tuile réellement publiée : sur un pack creux la tuile
		# exacte peut ne pas exister, et c'est son ancêtre qu'il faut rapatrier.
		var ns := t.y
		var ip := t.x
		while ns >= data.export_nside_min:
			if data.remote_source.has_tile(ns, ip):
				data.remote_source.queue(ns, ip)
				break
			ns >>= 1
			ip >>= 2
	return ready
