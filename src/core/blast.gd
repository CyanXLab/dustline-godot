class_name DLBlast extends RefCounted
## GrenadeBlastMath（移植）: 高斯爆炸伤害 + 护甲吸收
const UNIT := 0.0254
const HUMAN_HEIGHT := 1.8034   # 71u

static func damage(damage: float, radius: float, distance: float, exposure: float) -> float:
	var sigma := radius / 3.0
	var falloff := exp(-distance * distance / (2.0 * sigma * sigma))
	return damage * falloff * exposure

static func absorption(has_physics: bool, density: float) -> float:
	if not has_physics:
		return 0.75
	var r := density / 3000.0
	if r >= 0.0 and r < 1.0:
		return 1.0 - r
	return 0.0 if r < 0.0 else 1.0

## Armor — CS 护甲公式
static func armor(damage: float, weapon_ratio: float, armor_left: Array) -> float:
	if armor_left[0] <= 0:
		return damage
	var armor_damage := damage * weapon_ratio * 0.5
	var health_damage := (damage - armor_damage) * 0.5
	if health_damage > float(armor_left[0]):
		armor_damage = damage - float(armor_left[0]) / 0.5
		armor_left[0] = 0
	else:
		if health_damage < 0.0:
			health_damage = 1.0
		armor_left[0] = int(float(armor_left[0]) - health_damage)
	return armor_damage

static func candidate(source: Vector3, radius: float, feet: Vector3, h: float, half_width: float) -> bool:
	if feet.x + half_width >= source.x - radius and feet.x - half_width <= source.x + radius \
		and feet.z + half_width >= source.z - radius and feet.z - half_width <= source.z + radius \
		and feet.y + h >= source.y - radius:
		return feet.y <= source.y + radius
	return false

## 烟雾遮挡判定（移植 SmokeVisibility）— 返回被烟雾遮挡的视线长度(米)
static func smoke_blocking_length(radius: float, grenade_pos: Vector3, from: Vector3, to: Vector3) -> float:
	var r := radius / 0.0254
	var gpos := grenade_pos / 0.0254
	var f := from / 0.0254
	var t := to / 0.0254
	var r2 := r * r
	var v := t - f
	var total := sqrt(v.dot(v))
	if total < 1e-5:
		return 0.0
	v /= total
	var center := gpos + Vector3(0, 60, 0)
	var rs := sqrt(r2)
	var near := rs * 0.95
	var d1 := center - f
	var d2 := center - t
	if d1.dot(d1) < near * near or d2.dot(d2) < rs * rs:
		return -1.0  # 端点在烟里 → 完全遮挡
	var proj := (center - f).dot(v)
	var closest := f if proj < 0.0 else (t if proj >= total else f + v * proj)
	var dc := closest - center
	var dist_sq := dc.dot(dc)
	if dist_sq >= r2:
		return 0.0
	return 2.0 * sqrt(r2 - dist_sq) * 0.0254  # 回到米
