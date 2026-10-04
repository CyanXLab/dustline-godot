class_name DLMotor extends RefCounted
## Motor（逐常量移植 Motor.cs）: 64Hz CS2 风格移动
const FRICTION := 5.2
const ACCEL := 5.5
const AIR_ACCEL := 12.0
const AIR_SPEED_CAP := 0.762
const STOP_SPEED := 2.032
const BOMB_SPEED := 6.35
const DUCK_SPEED_FACTOR := 0.66   # 1-0.66*duck = 蹲行速度比

static func can_move(phase: int) -> bool:
        return phase == DL.RoundPhase.LIVE or phase == DL.RoundPhase.RESULT

static func step(p: DLPlayer, cmd: Dictionary, map: DLMap, others: Array) -> void:
        if not p.alive():
                return
        p.yaw = cmd.yaw
        p.pitch = cmd.pitch
        var vy_down: float = maxf(0.0, -p.velocity.y)
        p.stamina = DLStamina.recover(p.stamina, DL.DT)
        p.duck_cooldown = maxf(0.0, p.duck_cooldown - DL.DT)
        var was_grounded := p.grounded
        DLPlayerCollision.resolve_overlap(p, map, others)
        var ground_trace: Dictionary = DLTrace.world(map, p.position, Vector3(0, -0.06, 0), p.height())
        var g: bool = p.velocity.y <= 0.0 and bool(ground_trace.hit) and not bool(ground_trace.start_solid) and (ground_trace.normal as Vector3).y >= 0.7
        p.grounded = g
        if was_grounded and not p.grounded:
                pass
        if not was_grounded and p.grounded:
                p.stamina = DLStamina.land_cost(p.stamina, vy_down / 0.0254)
        var jump_pressed: bool = p.grounded and (int(cmd.buttons) & DL.B_JUMP) != 0 and (p.previous & DL.B_JUMP) == 0
        var crouch := _duck_input(p, (cmd.buttons & DL.B_CROUCH) != 0)
        _set_crouch(p, crouch, map, not p.grounded)
        p.walking = (cmd.buttons & DL.B_WALK) != 0 and not crouch and p.duck_fraction() <= 0.0
        var velocity := p.velocity
        # 地面摩擦
        if p.grounded:
                var flat := Vector2(velocity.x, velocity.z).length()
                if flat > 0.0:
                        var drop: float = maxf(flat, STOP_SPEED) * FRICTION * DL.DT
                        var nf: float = maxf(0.0, flat - drop)
                        velocity.x *= nf / flat
                        velocity.z *= nf / flat
                velocity.y = 0.0
        # 期望速度
        var fwd := DL.aim(cmd.yaw, 0.0)
        var right := Vector3(fwd.z, 0, -fwd.x)
        var wish := right * float(cmd.x) + fwd * float(cmd.z)
        var wish_len := minf(1.0, wish.length())
        if wish.length() > 1e-6:
                wish = wish.normalized()
        var wd := DLWeapons.get_weapon(p.gun)
        var scoped: bool = (int(cmd.buttons) & DL.B_SCOPE) != 0 and _scope_visible(p)
        var max_speed: float = float(wd.max_speed_alt) if scoped else float(wd.max_speed)
        var speed_factor := (1.0 - DUCK_SPEED_FACTOR * p.duck_fraction()) if p.duck_fraction() > 0.0 else (0.52 if p.walking else 1.0)
        var cap: float = (BOMB_SPEED if p.bomb_equipped else max_speed) * speed_factor
        cap *= (p.velocity_modifier if p.grounded else 1.0) * DLStamina.speed_multiplier(p.stamina)
        if (cmd.buttons & DL.B_FIRE) != 0 and p.since_shot < float(wd.cycle) * 2.0:
                cap *= float(wd.attack_speed_factor)
        var wish_speed := cap * wish_len
        var current := velocity.dot(wish)
        var add := (wish_speed if p.grounded else minf(wish_speed, AIR_SPEED_CAP)) - current
        if add > 0.0:
                var accel: float
                if p.grounded:
                        accel = _ground_accel(p, wd, max_speed, wish_speed, current, scoped)
                else:
                        accel = AIR_ACCEL * wish_speed
                velocity += wish * minf(accel * DL.DT, add)
        # 跳跃
        if jump_pressed:
                velocity.y = DLStamina.scale_jump(DL.JUMP_SPEED, p.stamina)
                p.grounded = false
                p.stamina = DLStamina.jump_cost(p.stamina, maxf(0.0, velocity.y) / 0.0254)
        if not p.grounded:
                velocity.y -= 0.15875  # 半步重力(64Hz×2)
        p.velocity = velocity
        _move(p, map, velocity, others)
        _check_stuck(p, map)
        p.position = map.fix_fallen(p.position)
        if not p.grounded:
                p.velocity.y -= 0.15875
        p.previous = cmd.buttons

static func _scope_visible(p: DLPlayer) -> bool:
        var wd := DLWeapons.get_weapon(p.gun)
        return wd.zoom_levels > 0 and p.zoom_level > 0 and p.reload_left <= 0.0

static func _ground_accel(p: DLPlayer, wd: Dictionary, max_speed: float, wish_speed: float, current: float, scoped: bool) -> float:
        var accel_mul := maxf(BOMB_SPEED, wish_speed)
        var speed_norm := minf(1.0, (BOMB_SPEED if p.bomb_equipped else max_speed) / BOMB_SPEED)
        var scoped_sniper: bool = not p.bomb_equipped and scoped and int(wd.zoom_levels) > 1 and max_speed * 0.52 < 2.794
        var ducking := p.duck_fraction() > 0.0
        var accel_factor := speed_norm if not ducking and not p.walking or scoped_sniper else 1.0
        var accel := accel_mul * speed_norm
        if ducking:
                accel *= 0.34
                accel_factor = minf(accel_factor, 0.34)
        if p.walking:
                accel *= 0.52
                if not scoped_sniper:
                        accel_factor *= 0.52
        var accel_speed := 5.5
        if p.walking and maxf(0.0, current) > accel - 0.127:
                accel_speed *= clampf((accel - maxf(0.0, current)) / 0.127, 0.0, 1.0)
        return accel_speed * accel_mul * accel_factor

static func _duck_input(p: DLPlayer, raw_crouch: bool) -> bool:
        if not p.duck_state_ready:
                p.duck_recovery_pos = p.position
                p.duck_state_ready = true
        var prev_crouch := (p.previous & DL.B_CROUCH) != 0
        if raw_crouch != prev_crouch:
                p.duck_speed = maxf(0.0, p.duck_speed - 2.0)
        var can := p.duck_speed >= 1.5 and (p.crouched or p.duck_cooldown <= 0.0)
        p.duck_speed = DL.move_val(p.duck_speed, 8.0, 3.0 * DL.DT)
        if p.duck_speed >= 8.0:
                p.duck_recovery_pos = p.position
        elif (p.duck_fraction() <= 0.0 or p.duck_fraction() >= 1.0) and (p.position - p.duck_recovery_pos).length() > 1.6256:
                p.duck_speed = DL.move_val(p.duck_speed, 8.0, 3.0 / 32.0)
        return raw_crouch and can

static func _set_crouch(p: DLPlayer, crouch: bool, map: DLMap, airborne: bool) -> void:
        var old_frac := p.duck_fraction()
        var target := 1.0 if crouch else 0.0
        var rate: float = p.duck_speed * 0.8 if crouch else maxf(1.5, p.duck_speed)
        var new_frac: float = target if airborne else DL.move_val(old_frac, target, DL.DT * rate)
        if absf(new_frac - old_frac) < 0.0001:
                p.duck_amount = old_frac
                return
        var will_crouch := new_frac >= 1.0 if crouch else (p.crouched and new_frac > 0.75)
        var y_off := 0.2286 * float((1 if will_crouch else 0) - (1 if p.crouched else 0)) if airborne else 0.0
        var v := p.position + Vector3(0, y_off, 0)
        if not crouch and not DLTrace.clear(map, p, v, DL.STAND_H, []):
                p.duck_amount = 1.0
                p.crouched = true
                return
        if not DLTrace.clear(map, p, v, DL.CROUCH_H if will_crouch else DL.STAND_H, []):
                p.duck_amount = old_frac
                return
        p.position = v
        p.duck_amount = new_frac
        p.crouched = will_crouch
        if crouch and new_frac >= 1.0 and old_frac < 1.0:
                p.duck_cooldown = 0.4

## SourceMotor.Move: 轴分离移动 + 自动上台阶 + ClipVelocity 滑墙
## (真实地图含斜墙/斜面: 命中后把速度投影到平面, 与原版引擎 ClipVelocity 一致)
static func _move(p: DLPlayer, map: DLMap, velocity: Vector3, others: Array) -> void:
        var delta := velocity * DL.DT
        # 轴分离 (Y -> X -> Z)
        var t := DLTrace.sweep(map, p, p.position, Vector3(0, delta.y, 0), p.height(), others)
        p.position.y += delta.y * t.fraction
        if t.hit and not t.start_solid:
                if delta.y < 0.0:
                        # 台阶尝试
                        _try_step(p, map, delta, others)
                        if p.grounded or absf(p.velocity.y) > 0.01:
                                p.velocity.y = 0.0
                                p.grounded = true
                else:
                        _clip_velocity(p, t.normal)
        t = DLTrace.sweep(map, p, p.position, Vector3(delta.x, 0, 0), p.height(), others)
        if t.start_solid and not t.hit:
                p.position.x += delta.x * t.fraction
        else:
                p.position.x += delta.x * t.fraction
                if t.hit and not t.start_solid:
                        _clip_velocity(p, t.normal)
        t = DLTrace.sweep(map, p, p.position, Vector3(0, 0, delta.z), p.height(), others)
        p.position.z += delta.z * t.fraction
        if t.hit and not t.start_solid:
                _clip_velocity(p, t.normal)

        # 地面吸附
        if p.velocity.y <= 0.0:
                var gt := DLTrace.world(map, p.position, Vector3(0, -DL.STEP_H * 0.5, 0), p.height())
                if gt.hit and not gt.start_solid:
                        p.position.y += -DL.STEP_H * 0.5 * float(gt.fraction)
                        p.grounded = true

static func _clip_velocity(p: DLPlayer, normal: Vector3) -> void:
        ## 去除陷入墙面的速度分量 (滑墙)
        var into := p.velocity.dot(normal)
        if into < 0.0:
                p.velocity -= normal * into

static func _try_step(p: DLPlayer, map: DLMap, delta: Vector3, others: Array) -> void:
        var orig := p.position
        # 上去
        var up: Dictionary = DLTrace.world(map, orig, Vector3(0, DL.STEP_H, 0), p.height())
        if bool(up.start_solid):
                return
        var raised: Vector3 = orig + Vector3(0, DL.STEP_H * float(up.fraction), 0)
        var fwd: Dictionary = DLTrace.sweep(map, p, raised, Vector3(delta.x, 0, delta.z), p.height(), others)
        var advanced: Vector3 = raised + Vector3(delta.x, 0, delta.z) * float(fwd.fraction)
        var down: Dictionary = DLTrace.world(map, advanced, Vector3(0, -DL.STEP_H, 0), p.height())
        if bool(down.hit) and not bool(down.start_solid):
                p.position = advanced + Vector3(0, -DL.STEP_H * float(down.fraction), 0)

static func _check_stuck(p: DLPlayer, map: DLMap) -> void:
        ## Source 引擎 CheckStuck 对应: 身位陷入 hull 时尝试向上/四周脱出
        if not map.world.clear(p.position, p.height()):
                for dy in [0.05, 0.1, 0.2, 0.35, 0.5, 0.75, 1.0, 1.3]:
                        if map.world.clear(p.position + Vector3(0, dy, 0), p.height()):
                                p.position.y += dy
                                p.grounded = false
                                return
                for off in [Vector3(0.3, 0.3, 0), Vector3(-0.3, 0.3, 0), Vector3(0, 0.3, 0.3), Vector3(0, 0.3, -0.3),
                                Vector3(0.6, 0.5, 0), Vector3(-0.6, 0.5, 0), Vector3(0, 0.5, 0.6), Vector3(0, 0.5, -0.6)]:
                        if map.world.clear(p.position + off, p.height()):
                                p.position += off
                                return
                p.position = map.world.ground_player(p.position + Vector3(0, 1.5, 0))
