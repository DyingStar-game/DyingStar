class_name VolcanoRandom
extends RefCounted
## Stateless deterministic noise shared by scheduling and visual effects.
## Keep independent of resources, nodes and the renderer.


static func hash01(n: int, salt: int) -> float:
	var x: int = (n * 73856093) ^ (salt * 19349663)
	x = (x ^ (x >> 13)) * 1274126177
	x = x ^ (x >> 16)
	return float(x & 0xFFFFF) / float(0xFFFFF)


static func noise1(x: float, salt: int) -> float:
	var i := floori(x)
	var f := x - float(i)
	f = f * f * (3.0 - 2.0 * f)
	return lerpf(hash01(i, salt), hash01(i + 1, salt), f)
