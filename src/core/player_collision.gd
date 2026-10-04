class_name DLPlayerCollision extends RefCounted
## PlayerCollision（移植 PlayerCollision.cs）: 玩家间推挤绕行

static func steer(p: DLPlayer, map: DLMap, delta: Vector3, others: Array) -> Vector3:
	var flat := Vector2(delta.x, delta.z).length()
	if flat < 0.1:
		return delta
	var dir := Vector3(delta.x, 0, delta.z) / flat
	var dist := minf(1.5, flat + 0.5)
	var t := DLTrace.players(p, p.position, dir * dist, p.height(), others)
	if not t.hit or t.normal.y > 0.7:
		return delta
	var best := dir
	var best_score := -100.0
	for i in 8:
		var ang := float(i / 2 + 1) * 30.0 * (1.0 if i % 2 == 0 else -1.0)
		var s := sin(deg_to_rad(ang))
		var c := cos(deg_to_rad(ang))
		var v3 := Vector3(dir.x * c + dir.z * s, 0, dir.z * c - dir.x * s)
		var t2 := DLTrace.sweep(map, p, p.position, v3 * dist, p.height(), others)
		if not t2.start_solid and not (t2.fraction < 0.12):
			var score: float = float(t2.fraction) * 1.8 + v3.dot(dir) * 0.6 + (0.025 if i % 2 == 0 else 0.0)
			if score > best_score:
				best_score = score
				best = v3
	return best * flat

static func resolve_overlap(p: DLPlayer, map: DLMap, others: Array) -> bool:
	if others == null or not p.alive():
		return false
	var t := DLTrace.players(p, p.position, Vector3.ZERO, p.height(), others)
	if not t.start_solid:
		return false
	var start := p.position
	if t.penetration < 0.65 and _try(map, p, start + t.normal * (t.penetration + 0.003), others):
		return true
	var step := 0.8158
	for i in range(1, 4):
		for j in range(-i, i + 1):
			for k in range(-i, i + 1):
				if maxi(absi(k), absi(j)) == i and _try(map, p, start + Vector3(k * step, 0, j * step), others):
					return true
	return false

static func _try(map: DLMap, p: DLPlayer, candidate: Vector3, others: Array) -> bool:
	if not DLTrace.clear(map, p, candidate, p.height(), others):
		return false
	var t := DLTrace.world(map, p.position, candidate - p.position, p.height())
	if t.start_solid or t.hit:
		return false
	p.position = candidate
	return true
