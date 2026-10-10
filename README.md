# DyingStar

### Getting started

To run the game with its servers on your machine, follow the local development guide of the
[kubernetes repository](https://github.com/DyingStar-game/kubernetes#local-development-minikube--argocd)
(section *Develop godot client & server*).

Contributing, with or without an AI coding agent: read [AGENTS.md](AGENTS.md) (rules, commands,
pitfalls) and the [architecture decision records](docs/adr/README.md) (why the code is the way it is).

### Planet data

Planet elevation streams from the tile service set under `[stream]` in `client.ini` and `server.ini`.
To design or import planet data, see `tools/planettech/qgis/README.md`.


### Code Organization

See this [documentation page](https://developer.dyingstar-game.com/docs/creativeConcept/files_structure/)



### Controls

In game, press F1 to see every control, with your own bindings.
- [Z][S][Q][D] = move
- [Shift] = hold to sprint
- [C] = toggle crouch or slide (when sprinting)
- [Space] = jump, hold near ledge while falling to grab
