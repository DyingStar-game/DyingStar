class_name AtomicFile
extends RefCounted
## Écriture « tout ou rien » d'un fichier de cache : un lecteur voit l'ancien contenu ou
## le nouveau, jamais un fichier à moitié écrit.
##
## Les caches disque (tuiles de hauteur, collisions pré-cuites) sont partagés entre tous
## les serveurs d'un même cluster — un volume ReadWriteMany monté sur [code]user://[/code]
## — pour qu'un serveur qui démarre (server meshing dynamique) trouve ce que les autres
## ont déjà téléchargé ou cuit. Deux serveurs peuvent donc écrire la même tuile au même
## moment, pendant qu'un troisième la lit. On écrit dans un fichier temporaire propre à
## l'écrivain, puis on le renomme sur la cible : le rename est atomique sur POSIX, et
## quand deux écrivains se croisent le dernier renommé gagne, avec le même contenu
## puisque les objets d'une version sont immuables.
##
## Le temporaire garde l'extension de la cible, précédée d'un suffixe [code].tmp[/code] :
## ResourceSaver choisit son format d'après l'extension, et les balayages du cache
## (TileCacheLru._scan) ne reconnaissent que [code]*.bin[/code] exact — un temporaire
## abandonné n'est donc jamais pris pour une tuile.


## Chemin temporaire unique à ce processus ET à cet appel (plusieurs fils écrivent).
static func temp_path(path: String) -> String:
	return "%s.%d-%d-%d.tmp.%s" % [path.get_basename(), OS.get_process_id(),
			Time.get_ticks_usec(), randi(), path.get_extension()]


## Renomme [param tmp] sur [param path]. Si le rename échoue alors que la cible existe,
## un autre écrivain vient de gagner : on jette notre temporaire et c'est un succès.
static func commit(tmp: String, path: String) -> bool:
	if DirAccess.rename_absolute(tmp, path) == OK:
		return true
	DirAccess.remove_absolute(tmp)
	return FileAccess.file_exists(path)


static func write_buffer(path: String, data: PackedByteArray) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp := temp_path(path)
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(data)
	f.close()
	return commit(tmp, path)


static func write_string(path: String, text: String) -> bool:
	return write_buffer(path, text.to_utf8_buffer())


static func write_var(path: String, value: Variant) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp := temp_path(path)
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_var(value)
	f.close()
	return commit(tmp, path)


## ResourceSaver.save, en atomique. Rend l'erreur de ResourceSaver, ou ERR_CANT_CREATE
## si le rename final a échoué.
static func save_resource(res: Resource, path: String, flags: int = 0) -> Error:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp := temp_path(path)
	var err := ResourceSaver.save(res, tmp, flags)
	if err != OK:
		DirAccess.remove_absolute(tmp)
		return err
	return OK if commit(tmp, path) else ERR_CANT_CREATE
