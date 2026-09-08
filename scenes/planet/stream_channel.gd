class_name StreamChannel
extends RefCounted
## Quel canal de tuiles ce processus utilise, et quelle version chaque corps y prend.
##
## Un canal est un manifeste `corps → version`, servi en un objet :
## `<base>/channels/<canal>.json`. Les arborescences de tuiles vivent en
## `<base>/<corps>/<version>/` et sont immuables : elles ne portent pas le nom du canal.
## Promouvoir, c'est donc faire monter le manifeste d'un cran sans recopier un octet, et
## la version servie en dev est littéralement la même que celle qui passe en preprod.
##
## [b]C'est là toute la poignée de main de version.[/b] Client et serveur ne négocient
## rien : ils résolvent le même nom de canal, lisent le même manifeste et obtiennent les
## mêmes versions par construction. Il ne reste qu'un risque, qu'ils soient sur des canaux
## différents — et [method fingerprint] est fait pour le rendre visible d'un coup d'œil
## dans deux journaux, sans nouveau message réseau.
##
## Cycle de vie, du moins stable au plus stable :
## [codeblock]
## unstable  →  dev  →  preprod  →  prod
## [/codeblock]

## Du moins stable au plus stable.
const CHANNELS := ["unstable", "dev", "preprod", "prod"]

## Canal retenu quand rien n'est configuré : celui que tous les développeurs partagent.
const DEFAULT_CHANNEL := "dev"

## Fichier estampillé au build. C'est la réponse au cas preprod : client et serveur y sont
## construits ensemble, donc écrire le canal dans le build les lie sans qu'aucun des deux
## n'ait à être configuré au déploiement.
const STAMP_PATH := "res://stream_channel.json"

## Manifeste résolu, partagé par toutes les planètes du processus. Le résoudre une fois
## évite dix-neuf requêtes là où une suffit, et surtout garantit que les dix-neuf corps
## viennent du MÊME manifeste : une promotion en cours de partie ne peut pas livrer
## tarsis_3 dans une version et sa lune dans une autre.
static var _resolved: Dictionary = {}
static var _resolved_for: String = ""


## Nom du canal, par la cascade habituelle du streaming :
## --tile-channel=, puis DS_TILE_CHANNEL, puis [stream] channel du .ini, puis
## l'estampille de build, puis DEFAULT_CHANNEL.
static func configured_name() -> String:
	var args: PackedStringArray = OS.get_cmdline_args() + OS.get_cmdline_user_args()
	for a: String in args:
		if a.begins_with("--tile-channel="):
			return _valid(a.split("=", true, 1)[1])
	var env := OS.get_environment("DS_TILE_CHANNEL")
	if env != "":
		return _valid(env)
	var ini: String = "server.ini" if OS.has_feature("dedicated_server") else "client.ini"
	for a: String in args:
		if a.contains("srvini="):
			ini = a.split("=")[1]
	var cfg := ConfigFile.new()
	if cfg.load(ini) == OK:
		var from_ini := str(cfg.get_value("stream", "channel", ""))
		if from_ini != "":
			return _valid(from_ini)
	return _valid(stamped_name())


## Canal écrit dans le build, ou "" s'il n'y en a pas.
static func stamped_name() -> String:
	if not FileAccess.file_exists(STAMP_PATH):
		return ""
	return str(parse_object(FileAccess.get_file_as_string(STAMP_PATH)).get("channel", ""))


## Un nom hors de la liste est une faute de frappe, pas un canal : mieux vaut retomber sur
## le défaut bruyamment que servir un manifeste inexistant en silence.
static func _valid(name: String) -> String:
	if name in CHANNELS:
		return name
	if name != "":
		push_warning("[StreamChannel] canal inconnu '%s' — repli sur '%s'"
				% [name, DEFAULT_CHANNEL])
	return DEFAULT_CHANNEL


## Objet JSON, ou {} si le texte n'en est pas un.
##
## JSON.parse_string() POUSSE une erreur moteur sur une entrée invalide. Or ce que l'on
## parse ici vient du réseau : une page d'erreur servie en 200 ferait crier le moteur à
## chaque tentative. L'instance rend un code, elle ne crie pas.
static func parse_object(text: String) -> Dictionary:
	var j := JSON.new()
	if j.parse(text) != OK:
		return {}
	return j.data if typeof(j.data) == TYPE_DICTIONARY else {}


static func url(base_url: String, channel: String) -> String:
	return "%s/channels/%s.json" % [base_url.rstrip("/"), channel]


## Résout le manifeste du canal une fois pour tout le processus.
##
## [param fetch] est un Callable(url) -> [code, PackedByteArray] ; les appelants passent
## celui de RemoteTileSource, et les tests le leur.
## Rend le dictionnaire `corps → bloc`, vide si le canal n'est pas servi — auquel cas
## l'appelant retombe sur le pointeur par corps, qui est le comportement d'avant.
static func resolve(base_url: String, fetch: Callable) -> Dictionary:
	var channel := configured_name()
	var key := "%s|%s" % [base_url.rstrip("/"), channel]
	if _resolved_for == key:
		return _resolved
	var res: Array = fetch.call(url(base_url, channel))
	var planets := {}
	if res[0] == 200:
		var got: Variant = parse_object(
				(res[1] as PackedByteArray).get_string_from_utf8()).get("planets", {})
		if typeof(got) == TYPE_DICTIONARY:
			planets = got
	_resolved = planets
	_resolved_for = key
	return planets


## Bloc d'un corps dans le canal résolu, ou {} s'il n'y figure pas.
## {} est normal : un corps peut n'avoir jamais été promu jusqu'à ce cran.
static func entry_for(planet: String) -> Dictionary:
	var e: Variant = _resolved.get(planet, {})
	return e if typeof(e) == TYPE_DICTIONARY else {}


## Empreinte courte de ce que ce processus a résolu : canal, nombre de corps, et un
## condensé des couples corps/version.
##
## Le seul écart que les canaux ne peuvent pas empêcher, c'est un client et un serveur
## sur des canaux DIFFÉRENTS. Cette ligne, dans les deux journaux, le montre sans qu'il
## faille comparer dix-neuf versions à la main ni ajouter un message réseau.
static func fingerprint() -> String:
	var names: Array = _resolved.keys()
	names.sort()
	var acc := ""
	for n: String in names:
		acc += "%s=%s;" % [n, entry_for(n).get("data_version", "?")]
	var digest := "vide" if acc == "" else "%08x" % acc.hash()
	return "canal=%s corps=%d empreinte=%s" % [configured_name(), names.size(), digest]


## Oublie le manifeste résolu. Pour les tests, et pour un changement de service en cours
## d'exécution.
static func reset() -> void:
	_resolved = {}
	_resolved_for = ""
