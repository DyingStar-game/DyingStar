class_name LocalFrame
extends RefCounted
## Transforms multiplied up a chain of LOCAL transforms, never read from two global ones. The world is
## some 4e10 m out, where a double tells positions apart by about 8 µm only: a point set through global
## positions came back a few µm off each frame, and an IK arm multiplied that into a visible shake
## (measured on the DataPad arm, 2026-10-15). Within a vehicle or a body, local transforms are exact.


## [param node]'s transform in [param ancestor]'s frame: the local transforms from [param node] up to
## (not including) [param ancestor], multiplied. Identity for the ancestor itself; the whole chain to the
## root when [param ancestor] is not above [param node].
static func of(node: Node, ancestor: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != ancestor:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf
