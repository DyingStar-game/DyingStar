# QGIS working directory for DyingStar planet data

This folder contains exported data for planets.

Structure:
- .export/ — temporary export files
- export/ — exported terrain and biome files for Godot import for each planet

## How to get files

The planet files are too big to put into repository.

For this reason, you must get the files, there are 2 ways to do this.


### Download planets files

The simple and quicky way is to download the last export

#### Files and folders

This is the files and folders in this qgis folder:

```
export/
  tarsis_1_chunks/
  tarsis_1_chunks/manifest.json
  tarsis_1_chunks/heights.pack
  ...
checksum.txt
creationtime.txt
README.md
```

`heights.pack` is a single dense archive holding every elevation tile of the
planet (all pyramid LOD levels, format DSHP v1 — authoritative spec in
`tools/qgis/export_elevation.py`). It replaces the old loose
`n{nside}/face_{face}/f{ipix}.r32` tree (~65 000 tiny files per planet), which
made archiving, downloading and the Godot export very slow. The runtime
(`scenes/planet/height_pack.gd`) reads elevation tiles exclusively from this
pack — old loose-tile exports must be re-exported with
`export_elevation.py`.

#### First get

In this case, you have only the `README.md` file

Download the archive [here](https://exportplanets.dyingstar-game.space/export.tar.gz)

Uncompress the archive (with 7-zip for example) and you will have the files and folder like defined in previous chapter.

You can now delete the archive `export.tar.gz`.


#### Update file with new version

We will update the planets data sometimes, and to check if new archive is available, you can check with 2 different methods:

- verify the checksum of server https://exportplanets.dyingstar-game.space/checksum.txt not have same value than the checksum.txt file in local
- verify the creationtime of server https://exportplanets.dyingstar-game.space/creationtime.txt not have same date than the creationtime.txt file in local

If different, delete `export` folder, `checksum.txt` and `creationtime.txt` and get like first time (previous chapter)


### How to export planets

The more longer way is to export yourself, but takes hours.

If you don't work on the QGIS planet maps, not use this, it's pointless.

Run the python script to export:

```sh
cd tools/qgis/
python3 export_all_planets.py
```


## Generate archive for developpers and release

```sh
cd assets/qgis/
```

1. create archive of the export folder

```sh
tar cvf export.tar export
```

2. generate the hash & creationdate

```sh
sha256sum export.tar > checksum.txt
```

3. set the date

```sh
stat -c '%w' export.tar > creationtime.txt
```

4. add hash and date in the archive

```sh
tar --append --file=export.tar checksum.txt 
tar --append --file=export.tar creationtime.txt
```

5. verify the liste of files in the archive file

```sh
tar --list --file=export.tar
```

6. compress the archive

```sh
gzip -9 export.tar
```

(or much faster on multi-core machines, same output format:
`pigz -9 export.tar`)

7. upload the files

Upload to the webserver in the folder `/var/www/html/dyingstar/planets/`.
