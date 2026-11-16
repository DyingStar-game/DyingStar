class_name FaceFitData
extends Resource

## Where MediaPipe's 478 face landmarks lie on our head, for fitting a face to photos in the game (FaceFit):
## each landmark is a point of one triangle of the bank's mesh (three vertices and their barycentric weights).
## Measured on our own neutral head (tools/character/face_survey/correspond.py: rays cast on its render), packed
## by tools/character/face_survey/pack_face_fit.tscn -- no person's data. Never edit by hand.
##
## It also carries the learned map from landmarks to the face's shape (tools/character/face_survey/regress.py,
## trained on our own renders of random FLAME faces, whose true shapes are known): MediaPipe's landmarks are loose,
## fitting our head's landmarks onto them barely finds a face, while a linear map learned over those renders
## predicts the face's dense shape a third nearer the truth. Aggregates of our renders only, no person's data.

const PATH: String = "res://assets/_universe/characters/human/face_fit.res"
const LANDMARKS: int = 478

## Per landmark, the three bank vertices (indices into HumanBank.base) of its triangle.
@export var vertices: PackedInt32Array
## Per landmark, the barycentric weights of those three vertices.
@export var bary: PackedFloat32Array
## Per landmark, 1 when it found our head (a few, deep in the mouth, did not).
@export var valid: PackedByteArray

@export_group("Shape regression")
## The bank vertices the predicted shape is given at (the face's front, regress.py face_vertex_set).
@export var shape_vertices: PackedInt32Array
## The mean of the predicted shapes: per shape vertex x, y, z (m, our head's frame).
@export var shape_mean: PackedFloat32Array
## The shape's principal directions: per component, per shape vertex x, y, z (row-major, components x vertices x 3).
@export var shape_components: PackedFloat32Array
## Each component's spread over the training faces (m): how far a prediction may go before it is extrapolating.
@export var shape_component_std: PackedFloat32Array
## Per view the regressions know (the front first, then the turned ones), the mean landmarks a photo's are aligned on
## first (x right, y up, z towards the camera; views x 478 x 3).
@export var shape_landmarks: PackedFloat32Array
## Per view, how its faces are turned in the image (FaceFit.turn's median over its renders): 0 the front, > 0 the
## nose towards the image's right, < 0 left.
@export var shape_view_turn: PackedFloat32Array
## One regression per set of views (all holding the front): { "mask": int (bit v for view v), "beta":
## PackedFloat32Array (features x components, row-major; features = 478 x 3 per view of the set, in view order),
## "feature_mean" / "feature_std": PackedFloat32Array (features), standardising them first, "error": its held-out
## shape error (m, median) }.
@export var shape_regressions: Array[Dictionary] = []

@export_group("Slider reader")
## The creator's shape sliders the reader gives, in its weights' order (FaceFit.keys()' shape keys).
@export var reader_keys: PackedStringArray
## The readers learnt on real faces (Ava-256, CC BY-NC 4.0: tools/character/face_survey/ava/ava_learn.py): photos'
## landmarks -> the sliders fitted to the people's 3D meshes, one per base body and set of views: { "female": bool
## (the default woman's body, else the man's), "mask": int (1 the front, 2 a side turned FaceFit.turn() > 0, 4 one
## turned < 0), "mean_landmarks": PackedFloat32Array (per view of the set, 478 x 3, the landmarks are aligned on),
## "feature_mean" / "feature_std": PackedFloat32Array (features), "beta": PackedFloat32Array (features x sliders,
## row-major), "weight_mean": PackedFloat32Array (sliders) }.
@export var reader_sets: Array[Dictionary] = []
## The share of the reader's sliders in the face made (0..1), the rest the landmark fit's: on the NoW benchmark's
## real scans each alone did worse than their half and half (front 1.72 and 1.78 mm, together 1.61).
@export var reader_blend: float = 0.5


static func load_shared() -> FaceFitData:
	return load(PATH) as FaceFitData if ResourceLoader.exists(PATH) else null


## True when the shape regression is packed (pack_face_fit.tscn --model=).
func has_shape_model() -> bool:
	return not shape_vertices.is_empty() and not shape_regressions.is_empty()


## True when the slider reader is packed (pack_face_fit.tscn --reader=).
func has_reader() -> bool:
	return not reader_keys.is_empty() and not reader_sets.is_empty()


## The reader of the [param female] or male base that uses the most of the views of [param mask] (1 front, 2 a side
## turned > 0, 4 one turned < 0), {} without one.
func reader(mask: int, female: bool) -> Dictionary:
	var best: Dictionary = {}
	for r: Dictionary in reader_sets:
		if bool(r["female"]) != female or int(r["mask"]) & ~mask != 0:
			continue
		if best.is_empty() or _bits(int(r["mask"])) > _bits(int(best["mask"])):
			best = r
	return best


static func _bits(mask: int) -> int:
	var n := 0
	while mask != 0:
		n += mask & 1
		mask >>= 1
	return n


## The shape regression's number of components.
func components() -> int:
	return shape_components.size() / maxi(shape_vertices.size() * 3, 1)


## The most accurate regression (held-out error) using only views of [param mask] (bit v for view v): {} without any.
func regression(mask: int) -> Dictionary:
	var best: Dictionary = {}
	for r: Dictionary in shape_regressions:
		if int(r["mask"]) & ~mask != 0:
			continue  # it needs a view there is no photo of
		if best.is_empty() or float(r["error"]) < float(best["error"]):
			best = r
	return best


## The mean landmarks of view [param view] (shape_landmarks' slice).
func view_landmarks(view: int) -> PackedFloat32Array:
	return shape_landmarks.slice(view * LANDMARKS * 3, (view + 1) * LANDMARKS * 3)


## The shape's vertices on a body of [param points] (the bank's vertex positions).
func shape_points(points: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(shape_vertices.size())
	for i in shape_vertices.size():
		out[i] = points[shape_vertices[i]]
	return out


## Per landmark, the normal of its triangle on a body of [param points] (outward: facing the camera on the face).
func normals(points: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(LANDMARKS)
	for i in LANDMARKS:
		var a: Vector3 = points[vertices[i * 3]]
		var n: Vector3 = (points[vertices[i * 3 + 1]] - a).cross(points[vertices[i * 3 + 2]] - a).normalized()
		out[i] = n
	if out[1].z < 0.0:  # the bank's triangles turn clockwise: the nose's tip must face forward (+Z)
		for i in LANDMARKS:
			out[i] = -out[i]
	return out


## The landmarks on a body of [param points] (the bank's vertex positions, HumanMorph.morph's).
func landmarks(points: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(LANDMARKS)
	for i in LANDMARKS:
		var p := Vector3.ZERO
		for j in 3:
			p += points[vertices[i * 3 + j]] * bary[i * 3 + j]
		out[i] = p
	return out
