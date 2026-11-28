class_name NoiseVolume
extends RefCounted
## A seamless 3D noise texture -- what a NoiseTexture3D with `seamless` makes (Noise.get_seamless_image_3d, its
## 0.1 blend skirt) -- its images made on a worker thread. A NoiseTexture3D makes its FIRST image on the main
## thread, at once, in the next message-queue flush (Godot 4.7 NoiseTexture3D::_update_texture, `first_time`):
## a volcano's two (96³ and 64³) cost ~1 s in the flush after the physics step that built it, which ClientPerf
## counted as physics engine time (2026-11-28).
##
## Never waits on the main thread: what needs the texture gives a callback (when_ready), called on the main
## thread once it exists -- at once when it already does.

var _noise: Noise
var _size: Vector3i
var _invert: bool
var _normalize: bool
var _images: Array[Image] = []
var _texture: ImageTexture3D = null
var _waiting: Array[Callable] = []


## Starts making the images of [param noise], [param size] voxels, on a worker.
func _init(noise: Noise, size: Vector3i, invert: bool = false, normalize: bool = true) -> void:
	_noise = noise
	_size = size
	_invert = invert
	_normalize = normalize
	PerfTasks.add_task("noise:volume", _make, false, "noise volume")


## The texture, null until its images are made.
func texture() -> ImageTexture3D:
	return _texture


## Calls [param callback] with the texture on the main thread once it exists (now, if it does).
func when_ready(callback: Callable) -> void:
	if _texture != null:
		callback.call(_texture)
	else:
		_waiting.append(callback)


func _make() -> void:
	var images: Array[Image] = []
	images.assign(_noise.get_seamless_image_3d(_size.x, _size.y, _size.z, _invert, 0.1, _normalize))
	PerfTasks.deferred("noise_volume:done", _done.bind(images))


func _done(images: Array[Image]) -> void:
	_images = images
	var tex := ImageTexture3D.new()
	tex.create(images[0].get_format(), _size.x, _size.y, _size.z, false, images)
	_texture = tex
	var waiting := _waiting
	_waiting = []
	for callback in waiting:
		if callback.is_valid():
			callback.call(tex)
