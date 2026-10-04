class_name DLWeapons extends RefCounted
## 武器数据 + 后坐力模式 + 精度系统（移植 Weapons.cs / SourceWeaponData.cs）

const RECOIL_SCALE := 2.0
const VIEW_RECOIL_TRACKING := 0.45
const VIEW_PUNCH_EXTRA := 0.055
const VIEW_PUNCH_DECAY := 18.0

static var _all: Array = []
static var _patterns: Array = []
static var _loaded := false

static func _load() -> void:
	if _loaded: return
	_loaded = true
	var f := FileAccess.open("res://assets/weapons.json", FileAccess.READ)
	if f == null:
		push_error("weapons.json 缺失")
		_all = [_default_weapon()]
		return
	var raw: Array = JSON.parse_string(f.get_as_text())
	for w in raw:
		_all.append(_normalize(w))
	# 扩展弹药长度一致性
	_build_patterns()

static func _default_weapon() -> Dictionary:
	return {"name": "匕首", "key": "knife", "category": "Knife", "damage": 50.0,
		"armor_ratio": 0.85, "range_modifier": 0.99, "cycle": 0.4, "reload": 0.0,
		"magazine": 0, "reserve": 0, "max_speed": 6.35, "base_spread": 0.0,
		"automatic": false, "slot": DL.WeaponSlot.KNIFE, "kind": DL.WeaponKind.KNIFE,
		"price": 0, "kill_award": 1500, "pellets": 1, "recoil_seed": 1, "spread_seed": 0,
		"zoom_levels": 0, "zoom_fov1": 90, "zoom_fov2": 90, "head_multiplier": 4.0,
		"penetration": 2.0, "range": 208.0768, "draw": 1.0, "attack_speed_factor": 1.0,
		"recoil_angle": 0.0, "recoil_angle_variance": 70.0, "recoil_magnitude": 30.0,
		"recoil_magnitude_variance": 0.0, "recovery_stand": 0.368, "recovery_crouch": 0.306,
		"recovery_stand_final": 0.506, "recovery_crouch_final": 0.42,
		"inaccuracy_stand": 0.0064, "inaccuracy_crouch": 0.0048, "inaccuracy_move": 0.175,
		"inaccuracy_fire": 0.0078, "inaccuracy_jump": 0.14, "inaccuracy_land": 0.00024,
		"inaccuracy_reload": 0.0, "spread_alt": 0.0006, "max_speed_alt": 5.46,
		"reload_commit": 0.0, "reload_start": 0.5, "reload_end": 0.4,
		"team_mask": 3, "shell_reload": false, "has_silencer": false,
		"hide_scoped": false, "unzoom_after_shot": false, "throw_velocity": 0.0}

static func _normalize(w: Dictionary) -> Dictionary:
	var d := _default_weapon()
	for k in d:
		if w.has(k) and w[k] != null:
			d[k] = w[k]
	for k in w:
		if not d.has(k):
			d[k] = w[k]
	# 缺省修正
	if not w.has("kill_award"): d["kill_award"] = 300 if d.kind == DL.WeaponKind.FIREARM else 1500
	return d

static func count() -> int:
	_load()
	return _all.size()

static func get_weapon(i: int) -> Dictionary:
	_load()
	if i < 0 or i >= _all.size():
		return _default_weapon()
	return _all[i]

static func is_firearm(g: int) -> bool:
	return g >= 0 and g < count() and get_weapon(g).kind == DL.WeaponKind.FIREARM

static func is_grenade(g: int) -> bool:
	return g >= DL.FLASH and g <= DL.INCENDIARY

static func is_pistol(g: int) -> bool:
	return is_firearm(g) and get_weapon(g).slot == DL.WeaponSlot.SECONDARY

static func buyable(g: int) -> bool:
	if g >= 0 and g < count() and g != DL.KNIFE and g != DL.C4:
		return get_weapon(g).price > 0
	return false

# ---------- 后坐力模式 ----------
static func _build_patterns() -> void:
	_patterns.clear()
	for i in _all.size():
		var wd: Dictionary = _all[i]
		var rng := SourceRandom.new(int(wd.recoil_seed))
		var arr: Array = []
		var smooth_a := 0.0
		var smooth_m := 0.0
		for k in 64:
			var va := float(wd.recoil_angle) + rng.rng_range(-float(wd.recoil_angle_variance), float(wd.recoil_angle_variance))
			var mag := float(wd.recoil_magnitude) + rng.rng_range(-float(wd.recoil_magnitude_variance), float(wd.recoil_magnitude_variance))
			if wd.automatic and k > 0:
				va = smooth_a + (va - smooth_a) * 0.55
				mag = smooth_m + (mag - smooth_m) * 0.55
			if wd.automatic and k < 4:
				mag *= 0.75 + 0.25 * float(k) / 4.0
			smooth_a = va
			smooth_m = mag
			arr.append(Vector2(sin(deg_to_rad(va)) * mag, cos(deg_to_rad(va)) * mag))
		_patterns.append(arr)

static func recoil_impulse(gun: int, index: int) -> Vector2:
	_load()
	if gun < 0 or gun >= _patterns.size():
		return Vector2.ZERO
	return _patterns[gun][clampi(index, 0, 63)]

# ---------- 精度 ----------
static func recovery(p: DLPlayer) -> float:
	var wd := get_weapon(p.gun)
	if not p.grounded:
		return maxf(0.03, float(wd.recovery_crouch) * 4.0)
	var base := float(wd.recovery_crouch if p.crouched else wd.recovery_stand)
	var final_v := float(wd.recovery_crouch_final if p.crouched else wd.recovery_stand_final)
	if final_v <= 0.0:
		final_v = base
	var t := 0.0
	var rs := float(wd.get("recovery_start", 2))
	var re := float(wd.get("recovery_end", 5))
	if re > rs:
		t = clampf((floorf(p.recoil_index) - rs) / (re - rs), 0.0, 1.0)
	return maxf(0.03, base + (final_v - base) * t)

static func accuracy_baseline(p: DLPlayer, alternate: bool) -> float:
	var wd := get_weapon(p.gun)
	var v: float
	if p.grounded:
		if p.crouched:
			v = float(wd.inaccuracy_crouch_alt if alternate and wd.has("inaccuracy_crouch_alt") else wd.inaccuracy_crouch)
		else:
			v = float(wd.inaccuracy_stand_alt if alternate and wd.has("inaccuracy_stand_alt") else wd.inaccuracy_stand)
	else:
		v = float(wd.inaccuracy_stand + wd.inaccuracy_jump)
	if p.reload_left > 0.0:
		v += float(wd.inaccuracy_reload)
	return v

static func update_accuracy(p: DLPlayer) -> void:
	var num := accuracy_baseline(p, false)
	if num > p.accuracy_penalty:
		p.accuracy_penalty = num
	else:
		p.accuracy_penalty = num + (p.accuracy_penalty - num) * exp(-log(10.0) * DL.DT / recovery(p))

static func inaccuracy(p: DLPlayer, scoped: bool) -> float:
	var wd := get_weapon(p.gun)
	var max_speed: float = float(wd.max_speed_alt) if scoped and float(wd.max_speed_alt) > 0.0 else float(wd.max_speed)
	var move_frac := clampf((p.velocity.length() - max_speed * 0.34) / (max_speed * 0.61), 0.0, 1.0)
	if not p.walking:
		move_frac = pow(move_frac, 0.25)
	var inaccuracy_move := float(wd.inaccuracy_move)
	if p.crouched:
		inaccuracy_move *= 0.34
	var total := accuracy_baseline(p, false)
	# 移动 + 开火扩散 + 跳跃着地
	total += inaccuracy_move * move_frac
	if p.since_shot < recovery(p):
		var fire_frac := clampf(1.0 - p.since_shot / maxf(0.001, recovery(p)), 0.0, 1.0)
		total += float(wd.inaccuracy_fire) * fire_frac
	if not p.grounded:
		total += float(wd.inaccuracy_jump)
	if p.grounded and p.velocity.y < -3.0:
		total += float(wd.inaccuracy_land) * absf(p.velocity.y)
	return total

## 射击方向（含后坐力偏移 + 扩散随机） — 移植 Weapons.ShotDirection
static func shot_direction(p: DLPlayer, spread_rand: SourceRandom, scoped: bool) -> Vector3:
	var wd := get_weapon(p.gun)
	var inacc := inaccuracy(p, scoped)
	var spread := float(wd.base_spread)
	var r1 := spread_rand.unit()
	var r2 := spread_rand.rng_range(0.0, PI * 2.0)
	var r3 := spread_rand.unit()
	var r4 := spread_rand.rng_range(0.0, PI * 2.0)
	# Negev 前几发大扩散
	if wd.key == "negev" and p.recoil_index < 3.0:
		var n := 3
		while n > int(p.recoil_index):
			r1 *= r1
			r3 *= r3
			n -= 1
		r1 = 1.0 - r1
		r3 = 1.0 - r3
	var sx := cos(r2) * r1 * inacc + cos(r4) * r3 * spread
	var sy := sin(r2) * r1 * inacc + sin(r4) * r3 * spread
	var yaw := p.yaw + p.recoil.x * RECOIL_SCALE
	var fwd := DL.aim(yaw, p.pitch - p.recoil.y * RECOIL_SCALE)
	var right := Vector3(cos(deg_to_rad(yaw)), 0, -sin(deg_to_rad(yaw)))
	var up := Vector3(fwd.y * right.z, fwd.z * right.x - fwd.x * right.z, -fwd.y * right.x)
	return (fwd + right * sx + up * sy).normalized()

static func step_recoil(p: DLPlayer, dt: float = DL.DT) -> void:
	p.view_punch *= exp(-VIEW_PUNCH_DECAY * dt)
	p.recoil *= exp(-8.0 * dt)
	var len := p.recoil.length()
	p.recoil = p.recoil * (1.0 - VIEW_PUNCH_DECAY * dt / len) if len > VIEW_PUNCH_DECAY * dt else Vector3.ZERO
	p.recoil += p.recoil_velocity * (dt * 0.5)
	p.recoil_velocity *= exp(-4.5 * dt)
	p.recoil += p.recoil_velocity * (dt * 0.5)
