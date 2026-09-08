extends GutTest
## Suite GUT pour [StreamChannel] — la poignée de main de version.
##
## Client et serveur ne négocient rien : ils résolvent le même nom de canal, lisent le
## même manifeste et obtiennent les mêmes versions par construction. Ce qui doit tenir :
##
##   1. Un manifeste fixe la version de TOUS les corps en une fois — une promotion en
##      cours de partie ne peut pas livrer tarsis_3 dans une version et sa lune dans une
##      autre.
##   2. Un canal absent retombe sur le pointeur par corps au lieu de casser.
##   3. Un nom de canal inconnu est une faute de frappe, pas un canal.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd \
##     -gtest=res://test/unit/test_stream_channel.gd -gexit


func before_each() -> void:
	StreamChannel.reset()


func after_all() -> void:
	StreamChannel.reset()


func _manifest(planets: Dictionary) -> Callable:
	var body := JSON.stringify({"channel": "dev", "planets": planets}).to_utf8_buffer()
	return func(url: String) -> Array:
		return [200, body] if url.ends_with(".json") else [404, PackedByteArray()]


func test_the_ladder_goes_from_unstable_to_prod() -> void:
	assert_eq(StreamChannel.CHANNELS, ["unstable", "dev", "preprod", "prod"])


func test_one_manifest_fixes_every_body_at_once() -> void:
	# La propriété qui fait la garantie : les dix-neuf corps viennent du MÊME manifeste,
	# donc une promotion en cours de partie ne peut pas les désynchroniser entre eux.
	var got := StreamChannel.resolve("http://h", _manifest({
		"tarsis_1": {"data_version": "a", "tile_res": 32},
		"tarsis_3": {"data_version": "b", "tile_res": 32},
	}))
	assert_eq(got.size(), 2)
	assert_eq(StreamChannel.entry_for("tarsis_3").get("data_version"), "b")
	assert_eq(StreamChannel.entry_for("tarsis_1").get("data_version"), "a")


func test_the_manifest_is_fetched_once_for_the_whole_process() -> void:
	# Dix-neuf corps, une requête — et surtout une seule lecture, donc une seule version
	# du monde même si le manifeste change pendant la partie.
	var calls := [0]
	var body := JSON.stringify({"planets": {"p": {"data_version": "a"}}}).to_utf8_buffer()
	var fetch := func(_url: String) -> Array:
		calls[0] += 1
		return [200, body]
	for _i in 5:
		StreamChannel.resolve("http://h", fetch)
	assert_eq(calls[0], 1, "une seule requête pour tout le processus")


func test_a_body_absent_from_the_channel_is_not_an_error() -> void:
	# Normal : un corps peut n'avoir jamais été promu jusqu'à ce cran.
	StreamChannel.resolve("http://h", _manifest({"tarsis_1": {"data_version": "a"}}))
	assert_eq(StreamChannel.entry_for("tarsis_3"), {})


func test_no_channel_served_falls_back_instead_of_breaking() -> void:
	# Le repli sur latest.json est le comportement d'avant les canaux : un service qui
	# n'en sert pas doit continuer de fonctionner.
	var got := StreamChannel.resolve("http://h", func(_u: String) -> Array:
		return [404, PackedByteArray()])
	assert_eq(got, {})


func test_a_corrupt_manifest_falls_back_too() -> void:
	# Une page d'erreur servie en 200 ne doit pas passer pour un manifeste.
	assert_eq(StreamChannel.resolve("http://h", func(_u: String) -> Array:
		return [200, "<html>oops</html>".to_utf8_buffer()]), {})


func test_an_unknown_channel_name_is_a_typo_not_a_channel() -> void:
	# Servir un manifeste inexistant en silence priverait la planète de tout terrain sans
	# que rien ne désigne la cause.
	assert_eq(StreamChannel._valid("prod"), "prod")
	assert_eq(StreamChannel._valid("preprd"), StreamChannel.DEFAULT_CHANNEL)
	assert_eq(StreamChannel._valid(""), StreamChannel.DEFAULT_CHANNEL)


func test_the_url_names_the_channel() -> void:
	assert_eq(StreamChannel.url("http://h/dist/", "preprod"),
			"http://h/dist/channels/preprod.json")


func test_the_fingerprint_separates_two_different_worlds() -> void:
	# C'est le seul écart que les canaux ne peuvent pas empêcher — deux processus sur des
	# canaux différents — et la ligne doit le rendre visible dans deux journaux.
	StreamChannel.resolve("http://h", _manifest({"p": {"data_version": "a"}}))
	var a := StreamChannel.fingerprint()
	StreamChannel.reset()
	StreamChannel.resolve("http://h2", _manifest({"p": {"data_version": "b"}}))
	assert_ne(a, StreamChannel.fingerprint(), "une version différente doit se voir")


func test_the_fingerprint_is_stable_for_the_same_world() -> void:
	StreamChannel.resolve("http://h", _manifest({"a": {"data_version": "1"},
			"b": {"data_version": "2"}}))
	var first := StreamChannel.fingerprint()
	StreamChannel.reset()
	# Même contenu, ordre d'insertion inverse : l'empreinte ne doit pas en dépendre.
	StreamChannel.resolve("http://h", _manifest({"b": {"data_version": "2"},
			"a": {"data_version": "1"}}))
	assert_eq(first, StreamChannel.fingerprint())


func test_an_empty_world_says_so_rather_than_hashing_nothing() -> void:
	StreamChannel.resolve("http://h", func(_u: String) -> Array:
		return [404, PackedByteArray()])
	assert_string_contains(StreamChannel.fingerprint(), "vide")
