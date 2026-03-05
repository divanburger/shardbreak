package main

import glsl "core:math/linalg/glsl"

vec2  :: glsl.vec2
ivec2 :: glsl.ivec2

Rect :: struct {
	min, max: vec2,
}

point_inside_rect :: proc(point: vec2, r: Rect) -> bool {
	return point.x >= r.min.x && point.x <= r.max.x &&
	       point.y >= r.min.y && point.y <= r.max.y
}

clamp2 :: proc(v, lo, hi: $T/[2]$E) -> T {
	return {clamp(v.x, lo.x, hi.x), clamp(v.y, lo.y, hi.y)}
}
