class_name DLPlayer extends RefCounted
## Player（移植 Player.cs）
var id := 0
var team := 0                # 0=CT 1=T
var gun := DL.KNIFE
var bot := false
var grounded := false
var crouched := false
var helmet := false
var defuse_kit := false
var bomb_equipped := false
var walking := false
var zoom_level := 0
var reload_stage := 0
var accuracy_penalty := 0.0
var recoil_index := 0.0
var flash_left := 0.0
var flash_peak := 0.0
var flash_start_tick := 0
var grenade_state := 0      # 0=无 1=拉环 2=投掷中
var grenade_gun := -1
var stamina := 0.0
var velocity_modifier := 1.0
var duck_amount := -1.0
var duck_speed := 8.0
var duck_cooldown := 0.0
var duck_recovery_pos := Vector3.ZERO
var duck_state_ready := false
var money := 800
var round_reward := 0
var inventory: int = 0       # 位掩码（≤63 把武器）
var position := Vector3.ZERO
var velocity := Vector3.ZERO
var recoil := Vector3.ZERO
var recoil_velocity := Vector3.ZERO
var view_punch := Vector3.ZERO
var yaw := 0.0
var pitch := 0.0
var reload_left := 0.0
var cooldown := 0.0
var since_shot := 10.0
var health := 100
var armor := 0
var kills := 0
var deaths := 0
var damage_accum := [0.0]
var shots := 0
var previous := 0
var ammo: PackedInt32Array = PackedInt32Array()
var reserve: PackedInt32Array = PackedInt32Array()
var alive_time := 0.0
# AI 扩展
var is_player_controlled := false
var ai_memory := {}          # bot 记忆（供 bot_ai 使用）

const AMMO_LEN := 43

func _init(p_id := 0, p_team := 0) -> void:
	id = p_id
	team = p_team
	ammo.resize(AMMO_LEN)
	reserve.resize(AMMO_LEN)
	for i in AMMO_LEN:
		ammo[i] = 0
		reserve[i] = 0

func owns(g: int) -> bool:
	if g == DL.KNIFE:
		return true
	if g >= 0 and g < AMMO_LEN:
		return (inventory & (1 << g)) != 0
	return false

func give(g: int, fill_ammo := true) -> void:
	inventory |= (1 << g)
	if fill_ammo:
		var wd := DLWeapons.get_weapon(g)
		ammo[g] = wd.magazine
		reserve[g] = wd.reserve

func take(g: int) -> void:
	inventory &= ~(1 << g)

func in_slot(slot: int) -> int:
	for i in 43:
		if slot == DL.WeaponSlot.PRIMARY and i >= DL.FIREARM_COUNT:
			break
		if owns(i):
			var wd := DLWeapons.get_weapon(i)
			if wd.slot == slot:
				return i
	return -1

func primary() -> int: return in_slot(DL.WeaponSlot.PRIMARY)
func secondary() -> int: return in_slot(DL.WeaponSlot.SECONDARY)
func best_gun() -> int:
	var p := primary()
	if p >= 0: return p
	var s := secondary()
	return s if s >= 0 else DL.KNIFE

func grenade_count() -> int:
	var n := 0
	for i in range(DL.FLASH, DL.INCENDIARY + 1):
		n += ammo[i]
	return n

func alive() -> bool: return health > 0

func height() -> float: return DL.CROUCH_H if crouched else DL.STAND_H

func eye() -> Vector3:
	var df := duck_fraction()
	return position + Vector3(0, DL.EYE_STAND - DL.EYE_DUCK_DROP * df * df * (3.0 - 2.0 * df), 0)

func duck_fraction() -> float:
	if duck_amount < 0.0:
		return 1.0 if crouched else 0.0
	return duck_amount

func reset_for_round(spawn_pos: Vector3) -> void:
	position = spawn_pos
	velocity = Vector3.ZERO
	recoil = Vector3.ZERO
	recoil_velocity = Vector3.ZERO
	view_punch = Vector3.ZERO
	health = 100
	grounded = true
	crouched = false
	duck_amount = -1.0
	duck_speed = 8.0
	duck_cooldown = 0.0
	zoom_level = 0
	reload_left = 0.0
	reload_stage = 0
	cooldown = 0.0
	since_shot = 10.0
	recoil_index = 0.0
	accuracy_penalty = 0.0
	stamina = 0.0
	grenade_state = 0
	grenade_gun = -1
	flash_left = 0.0
	bomb_equipped = false
	gun = best_gun()
	ai_memory = {}
