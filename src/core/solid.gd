class_name DLSolid extends RefCounted
## AABB 实体（移植 Solid.cs）: slab ray + overlap
var minv: Vector3
var maxv: Vector3
var material: int = DL.Surface.STONE
var name := ""

func _init(p_name: String, center: Vector3, size: Vector3, mat: int = DL.Surface.STONE) -> void:
	name = p_name
	minv = center - size * 0.5
	maxv = center + size * 0.5
	material = mat

func center() -> Vector3: return (minv + maxv) * 0.5
func size() -> Vector3: return maxv - minv

func overlaps(p_min: Vector3, p_max: Vector3) -> bool:
	return p_min.x < maxv.x - 0.0001 and p_max.x > minv.x + 0.0001 \
		and p_min.y < maxv.y - 0.0001 and p_max.y > minv.y + 0.0001 \
		and p_min.z < maxv.z - 0.0001 and p_max.z > minv.z + 0.0001

func ray(origin: Vector3, dir: Vector3, limit: float) -> Dictionary:
	## 返回 {hit, entry, exit}
	var entry := 0.0
	var exitv := limit
	var r: Array = _slab(origin.x, dir.x, minv.x, maxv.x, entry, exitv)
	entry = r[1]; exitv = r[2]
	if not r[0]:
		return {"hit": false, "entry": entry, "exit": exitv}
	r = _slab(origin.y, dir.y, minv.y, maxv.y, entry, exitv)
	entry = r[1]; exitv = r[2]
	if not r[0]:
		return {"hit": false, "entry": entry, "exit": exitv}
	r = _slab(origin.z, dir.z, minv.z, maxv.z, entry, exitv)
	entry = r[1]; exitv = r[2]
	return {"hit": r[0], "entry": entry, "exit": exitv}

static func _slab(o: float, d: float, mn: float, mx: float, enter: float, leave: float) -> Array:
	## 返回 [hit, enter, leave]
	if absf(d) < 1e-7:
		return [o >= mn and o <= mx, enter, leave]
	var t0 := (mn - o) / d
	var t1 := (mx - o) / d
	if t0 > t1:
		var tmp := t0; t0 = t1; t1 = tmp
	enter = maxf(enter, t0)
	leave = minf(leave, t1)
	return [leave >= enter, enter, leave]
