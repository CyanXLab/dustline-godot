class_name DLMap extends RefCounted
## MapLayout 移植 — 真实数据路径（与原版一致）:
## 原版 MapLayout.cs 在 SourceWorld 存在时: 出生点/包点/购买区/碰撞/寻路 全部来自 SourceWorld。
## 旧 40x42 网格仅为原版的 fallback，此处彻底移除，改用 world.dsw + terrain.dst 真实数据。

var world: DLSourceWorld
var spawn_ct := Vector3.ZERO
var spawn_t := Vector3.ZERO
var spawn_yaw_ct := 0.0
var spawn_yaw_t := 0.0
var site_a := Vector3.ZERO
var site_b := Vector3.ZERO
var cover_points_cache: Array = []

const CONTENT_DIR := "res://assets/content"

func _init(world_override: DLSourceWorld = null) -> void:
	if world_override != null:
		world = world_override
	else:
		world = DLSourceWorld.new(
			CONTENT_DIR + "/world.dsw",
			CONTENT_DIR + "/terrain.dst")
	if world == null or world.hulls.is_empty():
		push_error("SourceWorld 数据加载失败 — 碰撞将不可用")
		return
	spawn_ct = world.ground_player(world.get_spawn(0, 0).position)
	spawn_t = world.ground_player(world.get_spawn(1, 0).position)
	spawn_yaw_ct = world.get_spawn(0, 0).yaw
	spawn_yaw_t = world.get_spawn(1, 0).yaw
	site_a = world.site(1)
	site_b = world.site(2)

func spawn_for(team: int, ordinal: int) -> Dictionary:
	## {position, yaw} — 与原版 GetSpawn 一致 (ground 落地)
	return world.get_spawn(team, ordinal)

func bomb_site_at(p: Vector3) -> int:
	if world.contains(1, p):
		return 1
	if world.contains(2, p):
		return 2
	return 0

func in_buy_zone(p: Vector3, team: int) -> bool:
	return world.contains(3 if team == 0 else 4, p)

func clear_at(feet: Vector3, h := DL.STAND_H) -> bool:
	return world.clear(feet, h)

func ray_cast(start: Vector3, dir: Vector3, limit: float) -> Dictionary:
	## {hit, dist, material} — 原版 MapLayout.Ray: Sweep(start, dir*limit, 0, 0, mask=2)
	var d := dir.normalized() if dir.length() > 1e-8 else Vector3.ZERO
	var t := world.sweep(start, d * limit, 0.0, 0.0, 2)
	return {"hit": t.hit, "dist": t.fraction * limit, "material": t.material}

func visible(a: Vector3, b: Vector3) -> bool:
	var d := b - a
	var len := d.length()
	if len < 1e-5:
		return true
	return not ray_cast(a, d / len, len).hit

func path(from: Vector3, to: Vector3) -> PackedVector3Array:
	return world.path(from, to)

func fix_fallen(p_pos: Vector3) -> Vector3:
	## 掉出世界保护（地图 hull 理应封闭，双保险）
	if p_pos.y < -20.0:
		return world.ground_player(Vector3(p_pos.x, 3.0, p_pos.z))
	return p_pos

func nearest_nav(p: Vector3) -> int:
	return world.nearest(p)

func cover_points() -> Array:
	## 从真实导航 area 生成掩体点：贴墙且可站立的采样点
	if not cover_points_cache.is_empty():
		return cover_points_cache
	var pts: Array = []
	for a in world.areas:
		var size_x: float = a.se.x - a.nw.x
		var size_z: float = a.se.z - a.nw.z
		if size_x <= 0.0 or size_z <= 0.0:
			continue
		var nx := clampi(int(size_x / 1.6) + 1, 1, 5)
		var nz := clampi(int(size_z / 1.6) + 1, 1, 5)
		for i in nx:
			for j in nz:
				var fx := (float(i) + 0.5) / float(nx)
				var fz := (float(j) + 0.5) / float(nz)
				var base := a.point(a.nw.x + size_x * fx, a.nw.z + size_z * fz)
				var p := world.drop(Vector3(base.x, base.y + 0.05, base.z))
				if not world.clear(p, DL.STAND_H):
					continue
				for k in 8:
					var ang := float(k) * PI / 4.0
					var dir := Vector3(cos(ang), 0.0, sin(ang))
					var r := ray_cast(p, dir, 1.9)
					if r.hit:
						pts.append({"pos": p, "normal": -dir, "solid": "wall"})
						break
	cover_points_cache = pts
	return pts
