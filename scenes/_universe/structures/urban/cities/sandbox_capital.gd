extends NetStaticBody  # the uuid facade (see NetStaticBody)

## Networked city hub. All networking (uuid, replication, reparent, delete) lives in the PropSync child
## node (type_name "city", non-carriable). Many props are parented to the city, so the body exposes
## `uuid` for parent-by-uuid resolution. (The old nav-mesh bake and _align_to_surface paths were dead
## code and have been removed along with the networking boilerplate.)
