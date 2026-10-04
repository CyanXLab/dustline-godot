class_name DLHitboxes extends RefCounted
## 命中盒（CS 标准胶囊布局，简化自 SourceHitboxData）
## 返回每玩家局部胶囊列表 {a, b, radius, region}
## 局部空间: origin=脚底, -Z 朝前(与 aim(yaw,0) 对齐后旋转)

static var _stand: Array = []
static var _crouch: Array = []

static func _build() -> void:
	if _stand.size() > 0:
		return
	# region: 0=CHEST 1=HEAD 2=STOMACH 3=LEGS 4=NECK
	_stand = [
		{"a": Vector3(0, 1.5494, 0), "b": Vector3(0, 1.6764, 0), "r": 0.0762, "region": DL.HitRegion.HEAD},
		{"a": Vector3(0, 1.3970, 0), "b": Vector3(0, 1.4986, 0), "r": 0.0635, "region": DL.HitRegion.NECK},
		{"a": Vector3(0, 0.9906, 0), "b": Vector3(0, 1.3970, 0), "r": 0.1842, "region": DL.HitRegion.CHEST},
		{"a": Vector3(0, 0.7112, 0), "b": Vector3(0, 0.9906, 0), "r": 0.1651, "region": DL.HitRegion.STOMACH},
		{"a": Vector3(0.1016, 0.5588, 0), "b": Vector3(0.1016, 0.1016, 0), "r": 0.1016, "region": DL.HitRegion.LEGS},
		{"a": Vector3(-0.1016, 0.5588, 0), "b": Vector3(-0.1016, 0.1016, 0), "r": 0.1016, "region": DL.HitRegion.LEGS},
		{"a": Vector3(0.2540, 1.3208, 0), "b": Vector3(0.3048, 0.8128, 0), "r": 0.0762, "region": DL.HitRegion.CHEST},
		{"a": Vector3(-0.2540, 1.3208, 0), "b": Vector3(-0.3048, 0.8128, 0), "r": 0.0762, "region": DL.HitRegion.CHEST},
	]
	var shift := -0.3048
	_crouch = []
	for hb in _stand:
		var c := {"a": (hb.a as Vector3) + Vector3(0, shift, 0), "b": (hb.b as Vector3) + Vector3(0, shift, 0),
			"r": hb.r, "region": hb.region}
		_crouch.append(c)

static func boxes_for(crouched: bool) -> Array:
	_build()
	return _crouch if crouched else _stand

## 射线 vs 玩家: 返回 {hit, dist, region, exit}
static func ray_player(p: DLPlayer, start: Vector3, dir: Vector3, limit: float) -> Dictionary:
	var yaw_c := cos(deg_to_rad(p.yaw))
	var yaw_s := sin(deg_to_rad(p.yaw))
	var best := {"hit": false, "dist": limit, "region": DL.HitRegion.CHEST, "exit": 0.0}
	for hb in boxes_for(p.crouched):
		var a: Vector3 = p.position + _rot_y(hb.a, yaw_s, yaw_c)
		var b: Vector3 = p.position + _rot_y(hb.b, yaw_s, yaw_c)
		var r := capsule_ray(start, dir, limit, a, b, hb.r)
		if r.hit and r.entry < best.dist:
			best = {"hit": true, "dist": r.entry, "region": hb.region, "exit": r.exit}
	return best

static func _rot_y(v: Vector3, s: float, c: float) -> Vector3:
	return Vector3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c)

static func capsule_ray(start: Vector3, dir: Vector3, limit: float, a: Vector3, b: Vector3, radius: float) -> Dictionary:
	var enter := limit
	var exit_v := 0.0
	var hit := false
	# 两端球
	var sa := sphere_ray(start, dir, limit, a, radius)
	if sa.hit:
		enter = sa.entry
		exit_v = sa.exit
		hit = true
	var sb := sphere_ray(start, dir, limit, b, radius)
	if sb.hit:
		enter = minf(enter, sb.entry)
		exit_v = maxf(exit_v, sb.exit)
		hit = true
	var ab := b - a
	var length := ab.length()
	if length < 1e-6:
		return {"hit": hit, "entry": enter, "exit": exit_v}
	var n := ab / length
	var m := start - a
	var nn := dir.dot(n)
	var d := m - n * m.dot(n)
	var e := dir - n * nn
	var A := e.dot(e)
	var B := 2.0 * d.dot(e)
	var C := d.dot(d) - radius * radius
	var t_enter := 0.0
	var t_exit := limit
	if A < 1e-10:
		if C > 0.0:
			return {"hit": hit, "entry": enter, "exit": exit_v}
	else:
		var disc := B * B - 4.0 * A * C
		if disc < 0.0:
			return {"hit": hit, "entry": enter, "exit": exit_v}
		var sq := sqrt(disc)
		t_enter = maxf(t_enter, (-B - sq) / (2.0 * A))
		t_exit = minf(t_exit, (-B + sq) / (2.0 * A))
	if absf(nn) < 1e-7:
		if m.dot(n) < 0.0 or m.dot(n) > length:
			return {"hit": hit, "entry": enter, "exit": exit_v}
	else:
		var s1 := -m.dot(n) / nn
		var s2 := (length - m.dot(n)) / nn
		t_enter = maxf(t_enter, minf(s1, s2))
		t_exit = minf(t_exit, maxf(s1, s2))
	if t_exit >= t_enter:
		enter = minf(enter, t_enter)
		exit_v = maxf(exit_v, t_exit)
		hit = true
	return {"hit": hit, "entry": enter, "exit": exit_v}

static func sphere_ray(start: Vector3, dir: Vector3, limit: float, center: Vector3, radius: float) -> Dictionary:
	var v := start - center
	var A := dir.dot(dir)
	var B := v.dot(dir)
	var C := v.dot(v) - radius * radius
	if A < 1e-10:
		return {"hit": C <= 0.0, "entry": 0.0, "exit": limit}
	var disc := B * B - A * C
	if disc < 0.0:
		return {"hit": false, "entry": 0.0, "exit": 0.0}
	var sq := sqrt(disc)
	var entry := maxf(0.0, (-B - sq) / A)
	var exit_v := minf(limit, (-B + sq) / A)
	return {"hit": exit_v >= entry, "entry": entry, "exit": exit_v}

## 区域伤害倍率 (与原作 HeadMultiplier + CS 区域表一致)
static func region_multiplier(wd: Dictionary, region: int) -> float:
	match region:
		DL.HitRegion.HEAD:
			return float(wd.head_multiplier)
		DL.HitRegion.STOMACH:
			return 1.25
		DL.HitRegion.LEGS:
			return 0.75
		_:
			return 1.0
