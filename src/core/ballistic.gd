class_name DLBallistic extends RefCounted
## BallisticSurface + BulletPenetration + BulletRange + FractionalDamage（逐常量移植）

# name, GameMaterial(char), penetration modifier, damage modifier
const SURFACES := [
	["default", 67, 1.0, 0.5], ["solidmetal", 77, 0.27, 0.3], ["metal", 77, 0.4, 0.3],
	["metalgrate", 71, 0.95, 0.99], ["metalvent", 86, 0.6, 0.45], ["metalpanel", 86, 0.5, 0.45],
	["dirt", 68, 0.6, 0.3], ["grass", 74, 0.6, 0.3], ["tile", 84, 0.7, 0.3],
	["wood", 87, 0.9, 0.6], ["wood_plank", 87, 0.85, 0.6], ["wood_solid", 87, 0.8, 0.6], ["wood_dense", 13, 0.5, 0.3],
	["water", 83, 0.3, 0.5], ["ladder", 88, 0.4, 0.3], ["woodladder", 88, 0.9, 0.6],
	["glass", 89, 0.99, 0.5], ["computer", 80, 0.4, 0.45],
	["concrete", 67, 0.5, 0.25], ["asphalt", 81, 0.55, 0.3], ["rock", 3, 0.5, 0.25], ["brick", 82, 0.47, 0.25],
	["chainlink", 71, 0.99, 0.99], ["flesh", 70, 0.9, 0.5], ["armorflesh", 77, 0.5, 0.3],
	["carpet", 7, 0.75, 0.3], ["plaster", 2, 0.7, 0.6], ["sheetrock", 5, 0.85, 0.6],
	["cardboard", 85, 0.95, 0.99], ["plastic", 76, 0.75, 0.5], ["sand", 78, 0.3, 0.25],
	["rubber", 4, 0.85, 0.5],
]

const MAX_EXIT_DISTANCE := 2.286
const CHAR_WOOD := 87
const CHAR_METAL := 77
const CHAR_VENT := 86
const CHAR_GLASS := 89
const CHAR_GRATE := 71
const CHAR_PLASTIC := 76
const CHAR_CARDBOARD := 85
const CHAR_SAND := 78
const CHAR_FLESH := 70

static func surface_for(kind: int) -> Array:
	match kind:
		DL.Surface.FLESH: return ["flesh", 70, 0.9, 0.5]
		DL.Surface.SAND: return ["sand", 78, 0.3, 0.25]
		DL.Surface.CARDBOARD: return ["cardboard", 85, 0.95, 0.99]
		DL.Surface.PLASTIC: return ["plastic", 76, 0.75, 0.5]
		DL.Surface.GRATE: return ["grate", 71, 0.95, 0.99]
		DL.Surface.GLASS: return ["glass", 89, 0.99, 0.5]
		DL.Surface.METAL: return ["metal", 77, 0.4, 0.3]
		DL.Surface.WOOD: return ["wood", 87, 0.9, 0.6]
		_: return ["concrete", 67, 0.5, 0.25]

## BulletPenetration.Remaining — CS 穿墙衰减公式
static func remaining(damage: float, power: float, thickness: float, entry: Array, exit_s: Array, contents: int = 1, entry_flags: int = 0) -> float:
	var pen_mod := entry[2] as float
	var exit_mod := exit_s[2] as float
	if power <= 0.0 or thickness < 0.0 or thickness > MAX_EXIT_DISTANCE or pen_mod < 0.1 or exit_mod < 0.1:
		return 0.0
	var num := (pen_mod + exit_mod) * 0.5
	var num2 := 0.16
	var mat := entry[1] as int
	if mat == CHAR_GLASS or mat == CHAR_GRATE:
		num = 3.0
		num2 = 0.05
	elif (contents & 8) != 0 or (entry_flags & 0x80) != 0:
		num = 1.0
	if (entry[1] as int) == (exit_s[1] as int):
		var m2 := exit_s[1] as int
		if mat == CHAR_WOOD or m2 == CHAR_CARDBOARD:
			num = 3.0
		elif mat == CHAR_PLASTIC:
			num = 2.0
	var inv := 1.0 / num
	var thickness_units := thickness / 0.0254
	var num5 := damage * num2 + maxf(0.0, 3.0 / power * 1.25) * 3.0 * inv + thickness_units * thickness_units * inv / 24.0
	return maxf(0.0, damage - num5)

## BulletRange.Advance — 距离衰减 (range modifier^units/500)
static func advance(cumulative: Array, trace_length_units: float, trace_fraction: float, damage: float, range_modifier: float) -> float:
	cumulative[0] += trace_length_units * trace_fraction
	return damage * pow(range_modifier, cumulative[0] * 0.002)

## FractionalDamage.Apply — 伤害小数累积
static func apply_fractional(damage: float, accumulator: Array) -> int:
	if not DL.finite(damage) or damage <= 0.0:
		return 0
	var frac := damage - floorf(damage)
	var whole := damage - frac
	accumulator[0] += frac
	if accumulator[0] >= 1.0:
		whole += 1.0
		accumulator[0] -= 1.0
	return int(whole)
