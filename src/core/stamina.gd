class_name DLStamina extends RefCounted
## MovementStamina（CS2 体力跳跃系统，逐常量移植）
const MAXIMUM := 80.0
const RECOVERY_RATE := 60.0
const JUMP_PENALTY := 0.08
const LAND_PENALTY := 0.05

static func _remaining(stamina: float) -> float:
	return clampf(1.0 - stamina * 0.01, 0.0, 1.0)

static func recover(stamina: float, dt: float) -> float:
	return maxf(0.0, stamina - dt * RECOVERY_RATE)

static func speed_multiplier(stamina: float) -> float:
	var r := _remaining(stamina)
	return r * r

static func jump_cost(stamina: float, speed_units: float) -> float:
	return maxf(0.0, minf(MAXIMUM, stamina + speed_units * JUMP_PENALTY))

static func land_cost(stamina: float, speed_units: float) -> float:
	return maxf(0.0, minf(MAXIMUM, stamina + speed_units * LAND_PENALTY))

static func scale_jump(jump_speed: float, stamina: float) -> float:
	return jump_speed * sqrt(_remaining(stamina))
