class_name DL
## DUSTLINE 核心常量与工具（移植自 Dustline.Core）
## 坐标系: Y-up, 1 Godot 单位 = 1 米。CS 单位(0.0254m)换算见各常量。

enum Surface { STONE, WOOD, METAL, GLASS, GRATE, PLASTIC, CARDBOARD, SAND, FLESH }
enum RoundPhase { PREPARE, LIVE, RESULT, MATCH_OVER }
enum BombStage { CARRIED, DROPPED, PLANTED, DEFUSED, EXPLODED }
enum HitRegion { CHEST, HEAD, STOMACH, LEGS, NECK }
enum WeaponKind { FIREARM, KNIFE, TASER, GRENADE, BOMB }
enum WeaponSlot { PRIMARY, SECONDARY, KNIFE, TASER, GRENADE, BOMB }
enum GrenadePhase { FLYING, SMOKE, BURNING, DECOY, BLAST, FLASH, EXTINGUISHED }
enum BuyResult { NONE, PURCHASED, REFUNDED, NOT_REFUNDABLE, NO_MONEY, WRONG_TEAM, OUTSIDE_ZONE, TIME_OVER, NOT_ALIVE, ALREADY_OWNED, CARRY_LIMIT }

const DT := 1.0 / 64.0
const RADIUS := 0.4064          # 16u
const STAND_H := 1.8288         # 72u
const CROUCH_H := 1.3716        # 54u
const GRAVITY := 20.32          # 800u/s^2
const JUMP_SPEED := 7.67063
const STEP_H := 0.4572
const EYE_STAND := 1.6256       # 64u
const EYE_DUCK_DROP := 0.4572

const UNIT := 0.0254            # 1 CS unit in meters

# Buttons 位标志 (与 Command.Buttons 一致)
const B_FIRE := 1
const B_JUMP := 2
const B_CROUCH := 4
const B_WALK := 8
const B_RELOAD := 16
const B_SCOPE := 32
const B_USE := 64
const B_DROP_BOMB := 128
const B_BOMB_SEL := 256
const B_DROP_WEAPON := 512
const B_ALT_FIRE := 1024
const B_ZOOM2 := 2048

const KNIFE := 5
const FIREARM_COUNT := 34
const FLASH := 36
const HE := 37
const SMOKE := 38
const MOLOTOV := 39
const DECOY := 40
const INCENDIARY := 41
const C4 := 42

static func clampf(v: float, a: float, b: float) -> float:
	return minf(maxf(v, a), b)

static func move_val(cur: float, target: float, delta: float) -> float:
	if absf(target - cur) <= delta:
		return target
	return cur + signf(target - cur) * delta

static func aim(yaw_deg: float, pitch_deg: float) -> Vector3:
	var y := deg_to_rad(yaw_deg)
	var p := deg_to_rad(pitch_deg)
	return Vector3(sin(y) * cos(p), -sin(p), cos(y) * cos(p))

static func finite(v: float) -> bool:
	return not (is_nan(v) or is_inf(v))
