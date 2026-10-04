class_name DLMatch extends RefCounted
## 主模拟（移植 Match.cs/Game.cs 规则 + 增强）: 回合流程/开火/投掷物/炸弹/经济/多模式
signal event_gear(player_id: int)
signal event_buy_result(result: int)
signal event_kill(killer: int, victim: int, weapon: int, headshot: bool, penetrated: bool)
signal event_impact(pos: Vector3, material: int, kind: int)
signal event_sound(name: String, pos: Vector3, player_id: int)
signal event_grenade(action: String, g: Dictionary)
signal event_bomb(action: String, site: int, pos: Vector3, player_id: int)
signal event_round(phase: int, winner: int, reason: String)
signal event_hit_feedback(attacker: int, victim: int, region: int, damage: int, killed: bool)

enum Mode { DEFUSAL, TDM, WAVE }

const RULES := {
        "start_money": 800, "max_money": 16000, "half_rounds": 15, "win_score": 16,
        "freeze_time": 6.0, "round_time": 115.0, "buy_time": 20.0, "result_time": 7.0,
        "plant_time": 3.2, "bomb_time": 40.0, "defuse_time": 10.0, "kit_time": 5.0,
}

var map: DLMap
var mode: int = Mode.DEFUSAL
var players: Array = []
var tick := 0
var round_num := 1
var phase: int = DL.RoundPhase.PREPARE
var bomb_stage: int = DL.BombStage.CARRIED
var _bot_bought: Dictionary = {}
var phase_left: float = RULES.freeze_time
var bomb := {"stage": DL.BombStage.CARRIED, "carrier": 255, "actor": 255, "site": 0,
        "position": Vector3.ZERO, "progress": 0.0, "time_left": RULES.bomb_time}
var grenades: Array = []
var score := [0, 0]
var loss_streak := [0, 0]
var wave := 0
var wave_left := 0
var rng := SourceRandom.new(-4717)
var commands: Array = []
var deaths_this_round := 0
var match_over := false
var winner := -1
var cover_points: Array = []
var _smokes: Array = []   # {pos, radius, left}

func _init(p_mode: int = Mode.DEFUSAL, bot_count: int = 8) -> void:
        map = DLMap.new()
        mode = p_mode
        cover_points = map.cover_points()
        var humans := 1
        for i in humans + bot_count:
                var p := DLPlayer.new(i, 0 if i % 2 == 0 else 1)
                p.bot = i >= humans
                p.is_player_controlled = i == 0
                players.append(p)
        for p in players:
                p.give(DL.KNIFE)
                p.give(4 if p.team == 0 else 3, true)  # CT=USP-S(4) T=Glock(3)
        match_reset(true)

func _starting_pistol(team: int) -> int:
        # 从武器表里找对应手枪
        for i in DLWeapons.count():
                var wd := DLWeapons.get_weapon(i)
                if wd.kind == DL.WeaponKind.FIREARM and wd.slot == DL.WeaponSlot.SECONDARY and wd.price == 200:
                        if team == 0 and wd.key == "usp":
                                return i
                        if team == 1 and wd.key == "glock":
                                return i
        var fallback := 4
        return fallback

func match_reset(full := false) -> void:
        score = [0, 0]
        loss_streak = [0, 0]
        wave = 0
        round_num = 1
        match_over = false
        for p in players:
                p.money = RULES.start_money
                p.kills = 0
                p.deaths = 0
        round_reset()


# ---------------- 购买系统 (原版 Match.CanBuy/TryBuy/AutoBuy + Shop 移植) ----------------
const BUY_ARMOR := 6
const BUY_HELMET := 7
const BUY_KIT := 8

func _grenade_count(p: DLPlayer) -> int:
    var n := 0
    for g in [DL.FLASH, DL.HE, DL.SMOKE, DL.MOLOTOV, DL.DECOY, DL.INCENDIARY]:
        if p.owns(g):
            n += int(p.ammo[g] if p.ammo.has(g) else 0)
    return n

func _can_carry_grenade(p: DLPlayer, g: int) -> bool:
    ## Equipment.CanCarryGrenade: 总数≤4, 闪光≤2, 燃烧瓶/燃烧弹互斥
    if _grenade_count(p) >= 4 or int(p.ammo[g] if p.ammo.has(g) else 0) >= (2 if g == DL.FLASH else 1):
        return false
    if g == DL.MOLOTOV:
        return not p.owns(DL.INCENDIARY)
    if g == DL.INCENDIARY:
        return not p.owns(DL.MOLOTOV)
    return true

func buy_price(item: int, p: DLPlayer) -> int:
    ## Shop.Price: 6=护甲650 7=头盔(1000/350/650) 8=拆弹器400, 武器=16+gun
    var gun := item - 16
    if gun >= 0:
        return int(DLWeapons.get_weapon(gun).price)
    match item:
        BUY_KIT: return 400
        BUY_HELMET:
            if not p.helmet:
                return 1000 if p.armor != 100 else 350
            return 650
        BUY_ARMOR: return 650
        _: return 0

func _team_allows(item: int, team: int) -> bool:
    var gun := item - 16
    if gun < 0:
        return team == 0 if item == BUY_KIT else true
    return (int(DLWeapons.get_weapon(gun).teammask) & (1 << team)) != 0

func can_buy(p: DLPlayer, item: int) -> int:
    ## Match.CanBuy 1:1 → DL.BuyResult
    if not p.alive():
        return DL.BuyResult.NOT_ALIVE
    if (phase != DL.RoundPhase.PREPARE and phase != DL.RoundPhase.LIVE) or _buy_left() <= 0.0 			or bomb_stage == DL.BombStage.PLANTED:
        return DL.BuyResult.TIME_OVER
    if not map.in_buy_zone(p.position, p.team):
        return DL.BuyResult.OUTSIDE_ZONE
    if not _team_allows(item, p.team):
        return DL.BuyResult.WRONG_TEAM
    var gun := item - 16
    if gun >= 0 and DLWeapons.is_grenade(gun) and not _can_carry_grenade(p, gun):
        return DL.BuyResult.CARRY_LIMIT
    if (gun >= 0 and not DLWeapons.is_grenade(gun) and p.owns(gun)) \
            or (item == BUY_ARMOR and p.armor == 100) \
            or (item == BUY_HELMET and p.helmet and p.armor == 100) \
            or (item == BUY_KIT and p.defuse_kit):
        return DL.BuyResult.ALREADY_OWNED
    if buy_price(item, p) > p.money:
        return DL.BuyResult.NO_MONEY
    return DL.BuyResult.PURCHASED

func _buy_left() -> float:
    ## 购买窗口: 冻结期 + 开局 buy_time 秒
    if phase == DL.RoundPhase.PREPARE:
        return 1.0
    if phase == DL.RoundPhase.LIVE:
        return maxf(0.0, float(RULES.buy_time) - (float(RULES.round_time) - phase_left))
    return 0.0

func try_buy(p: DLPlayer, item: int) -> int:
    if item <= 0:
        return DL.BuyResult.NONE
    var res := can_buy(p, item)
    if res != DL.BuyResult.PURCHASED:
        return res
    var price := buy_price(item, p)
    p.money -= price
    var gun := item - 16
    if gun >= 0:
        if DLWeapons.is_grenade(gun):
            p.give(gun, false)
            p.ammo[gun] = int(p.ammo[gun] if p.ammo.has(gun) else 0) + 1
            return res
        var old := p.in_slot(int(DLWeapons.get_weapon(gun).slot))
        if old >= 0:
            p.take(old)
            p.ammo[old] = 0
        p.give(gun)
        p.gun = gun
        p.zoom_level = 0
        event_gear.emit(p.id)
    elif item == BUY_KIT:
        p.defuse_kit = true
    else:
        p.armor = 100
        if item == BUY_HELMET:
            p.helmet = true
    return res

func auto_buy(p: DLPlayer) -> void:
    ## Match.AutoBuy 1:1: AWP(每5号位且钱够) / AK(T) / M4(CT) + 头盔/护甲 + 拆弹器 + 手雷
    if p.primary() < 0:
        var main := (3 if (p.id % 5 == 0 and p.money >= 5750) else (1 if p.team != 0 else 2))
        # BuyItem.AK=1→gun0? 原版: AK item=1 对应 gun index: Item(gun)=16+gun; AK=1 → gun=-15?
        # 原版 BuyItem.AK=1 直接枚举; 这里用 gun id: AK=7, M4=8, AWP=9 (weapons.json 顺序)
        try_buy(p, 16 + (9 if main == 3 else (7 if main == 1 else 8)))
    if try_buy(p, BUY_HELMET) == DL.BuyResult.NO_MONEY:
        try_buy(p, BUY_ARMOR)
    if p.team == 0:
        try_buy(p, BUY_KIT)
    if p.money > 1000:
        try_buy(p, 16 + DL.HE)
        try_buy(p, 16 + DL.SMOKE)
        try_buy(p, 16 + DL.FLASH)

func spawn_point(team: int, idx: int) -> Vector3:
        ## 原版 GetSpawn: 真实出生点轮换 (ground 落地)
        return map.spawn_for(team, idx).position

func spawn_yaw(team: int, idx: int) -> float:
        return map.spawn_for(team, idx).yaw

func alive_count(team: int) -> int:
        var n := 0
        for p in players:
                if p.alive() and p.team == team:
                        n += 1
        return n

func round_reset() -> void:
        phase = DL.RoundPhase.PREPARE
        phase_left = RULES.freeze_time if mode == Mode.DEFUSAL else 3.0
        deaths_this_round = 0
        _bot_bought.clear()
        _smokes = []
        for g in grenades:
                event_grenade.emit("remove", g)
        grenades = []
        bomb = {"stage": DL.BombStage.CARRIED, "carrier": 255, "actor": 255, "site": 0,
                "position": Vector3.ZERO, "progress": 0.0, "time_left": RULES.bomb_time}
        var t_idx := 0
        var ct_idx := 0
        for p in players:
                var team_idx: int = t_idx if p.team == 1 else ct_idx
                if p.team == 1: t_idx += 1
                else: ct_idx += 1
                p.reset_for_round(spawn_point(p.team, team_idx))
                p.yaw = spawn_yaw(p.team, team_idx)
                p.health = 100
                # 武器保留: 原作死亡掉枪 — 简化: 死亡失去主武器, 存活保留
                if mode == Mode.DEFUSAL and bool(p.ai_memory.get("died_last_round", false)):
                        _strip_to_pistol(p)
                p.gun = p.best_gun()
        # 炸弹给随机 T
        if mode == Mode.DEFUSAL:
                var ts := []
                for p in players:
                        if p.team == 1:
                                ts.append(p)
                if ts.size() > 0:
                        var carrier: DLPlayer = ts[rng.int_range(0, ts.size() - 1)]
                        bomb.carrier = carrier.id
        # 波次模式
        if mode == Mode.WAVE:
                wave = 0

func _strip_to_pistol(p: DLPlayer) -> void:
        for i in DLWeapons.count():
                var wd := DLWeapons.get_weapon(i)
                if wd.slot == DL.WeaponSlot.PRIMARY and p.owns(i):
                        p.take(i)
                        p.ammo[i] = 0

func _dlp_has_flag(p: DLPlayer) -> bool:
        # deaths_last_round 占位: 用 ai_memory 标记
        return p.ai_memory.get("died_last_round", false)

func start_live() -> void:
        phase = DL.RoundPhase.LIVE
        phase_left = RULES.round_time

func step() -> void:
        if match_over:
                return
        tick += 1
        phase_left -= DL.DT
        # 玩家指令
        for p in players:
                if p.id >= commands.size():
                        commands.append(_idle_command(p))
                var cmd: Dictionary = commands[p.id] if p.id < commands.size() else _idle_command(p)
                if phase == DL.RoundPhase.PREPARE:
                        cmd = _freeze_command(cmd)
                # 购买: 原版在 Prepare/Live 且购买窗口内处理 command.Buy
                var buy_item: int = int(cmd["buy"]) if cmd.has("buy") else 0
                if buy_item > 0:
                        var bres: int = try_buy(p, buy_item)
                        cmd["buy"] = 0
                        if p.id == 0:
                                event_buy_result.emit(bres)
                # 原版: bot 冻结期自动购买一次
                if p.bot and phase == DL.RoundPhase.PREPARE and not _bot_bought.get(p.id, false):
                        auto_buy(p)
                        _bot_bought[p.id] = true
                if p.alive():
                        DLMotor.step(p, cmd, map, players)
                        DLWeapons.step_recoil(p)
                        _step_weapon(p, cmd)
                        _step_grenade_throw(p, cmd)
                else:
                        p.velocity = Vector3.ZERO
        # 炸弹
        if mode == Mode.DEFUSAL:
                _step_bomb()
        # 投掷物
        _step_grenades()
        # 烟雾计时
        for s in _smokes:
                s.left -= DL.DT
        _smokes = _smokes.filter(func(s): return s.left > 0.0)
        # 回合结束判定
        _check_round_end()

func _idle_command(p: DLPlayer) -> Dictionary:
        return {"x": 0.0, "z": 0.0, "yaw": p.yaw, "pitch": p.pitch, "buttons": 0, "weapon": p.gun, "buy": 0}

func _freeze_command(cmd: Dictionary) -> Dictionary:
        ## 原版冻结期: 只允许视角转动, 禁止移动/开火
        var c := cmd.duplicate()
        c.buttons = 0
        c.x = 0.0
        c.z = 0.0
        return c

func set_command(id: int, cmd: Dictionary) -> void:
        while commands.size() <= id:
                commands.append(_idle_command(players[0]))
        commands[id] = cmd

# ---------------- 武器开火/换弹 ----------------
func _step_weapon(p: DLPlayer, cmd: Dictionary) -> void:
        p.since_shot += DL.DT
        p.cooldown = maxf(0.0, p.cooldown - DL.DT)
        p.flash_left = maxf(0.0, p.flash_left - DL.DT)
        DLWeapons.update_accuracy(p)
        # 换弹
        if p.reload_left > 0.0:
                p.reload_left -= DL.DT
                if p.reload_left <= 0.0:
                        var wd := DLWeapons.get_weapon(p.gun)
                        var need := int(wd.magazine) - p.ammo[p.gun]
                        var take_v := mini(need, p.reserve[p.gun])
                        p.ammo[p.gun] += take_v
                        p.reserve[p.gun] -= take_v
                        p.reload_stage = 0
                        event_sound.emit("reload_end", p.position, p.id)
                return
        # 切换武器
        var want: int = cmd.weapon
        if want != p.gun and p.owns(want):
                p.gun = want
                p.reload_left = 0.0
                p.zoom_level = 0
                event_sound.emit("draw", p.position, p.id)
        # 缩放
        var wd := DLWeapons.get_weapon(p.gun)
        if (cmd.buttons & DL.B_SCOPE) != 0 and int(wd.zoom_levels) > 0 and (p.previous & DL.B_SCOPE) == 0:
                p.zoom_level = (p.zoom_level + 1) % (int(wd.zoom_levels) + 1)
                event_sound.emit("zoom", p.position, p.id)
        # 换弹键
        if (cmd.buttons & DL.B_RELOAD) != 0 and DLWeapons.is_firearm(p.gun):
                if p.ammo[p.gun] < int(wd.magazine) and p.reserve[p.gun] > 0 and p.reload_left <= 0.0:
                        p.reload_left = float(wd.reload_commit)
                        p.reload_stage = 1
                        p.zoom_level = 0
                        event_sound.emit("reload", p.position, p.id)
                return
        # 开火
        if (cmd.buttons & DL.B_FIRE) != 0 and _can_move_shoot():
                if DLWeapons.is_grenade(p.gun):
                        return  # 投掷由 _step_grenade_throw 处理
                _try_fire(p, cmd)

func _can_move_shoot() -> bool:
        return phase == DL.RoundPhase.LIVE or phase == DL.RoundPhase.RESULT

func _try_fire(p: DLPlayer, cmd: Dictionary) -> void:
        var wd := DLWeapons.get_weapon(p.gun)
        if p.cooldown > 0.0:
                return
        if wd.kind == DL.WeaponKind.KNIFE:
                p.cooldown = 0.4
                _knife_attack(p, cmd)
                return
        if wd.kind != DL.WeaponKind.FIREARM:
                return
        if p.ammo[p.gun] <= 0:
                p.cooldown = 0.25
                event_sound.emit("empty", p.position, p.id)
                return
        p.ammo[p.gun] -= 1
        p.shots += 1
        p.cooldown = float(wd.cycle)
        p.since_shot = 0.0
        # 后坐力
        var ri := int(p.recoil_index)
        var imp := DLWeapons.recoil_impulse(p.gun, ri)
        var mag := Vector2(imp.y, imp.x)  # (纵向, 横向) 视缩放
        p.recoil_velocity += Vector3(mag.y, mag.x, 0) * 0.045
        p.view_punch += Vector3(mag.y * 0.03, mag.x * 0.05, 0)
        p.recoil_index = fmod(p.recoil_index + 1.0, 64.0)
        event_sound.emit("shot_%s" % wd.key, p.position, p.id)
        # 命中判定（每颗弹丸）
        var spread := SourceRandom.new(int(rng.int_range(0, 2147483000)))
        for pellet in maxi(1, int(wd.pellets)):
                var dir := DLWeapons.shot_direction(p, spread, p.zoom_level > 0)
                _fire_ray(p, wd, p.eye(), dir)
        # 通知 AI: 枪声
        _noise_event(p.position, 60.0, p.id)

func _knife_attack(p: DLPlayer, cmd: Dictionary) -> void:
        event_sound.emit("knife_swing", p.position, p.id)
        var dir := DL.aim(cmd.yaw, cmd.pitch)
        var eye := p.eye()
        for q in players:
                var q2: DLPlayer = q
                if q2.id == p.id or not q2.alive() or q2.team == p.team:
                        continue
                var hb := DLHitboxes.ray_player(q2, eye, dir, 1.0)
                if hb.hit:
                        _apply_damage(p, q2, wd_for(DL.KNIFE), 50.0, hb.region, false)
                        event_sound.emit("hit_flesh", q2.position, p.id)
                        return
        # 挥空 → 砍墙判定
        var r := map.ray_cast(eye, dir, 1.0)
        if r.hit:
                event_impact.emit(eye + dir * r.dist, r.material, 0)

func wd_for(gun: int) -> Dictionary:
        return DLWeapons.get_weapon(gun)

## 射线: 穿墙 + 命中玩家（移植子弹穿透逻辑）
func _fire_ray(shooter: DLPlayer, wd: Dictionary, origin: Vector3, dir: Vector3) -> void:
        ## Match.TraceBullet 1:1 移植: SourceWorld.Walls 区间 + 玩家命中盒 → 排序 →
        ## BulletRange 分段衰减 + BulletPenetration 穿墙 (≤4 层, 累计 3000u 上限)
        var gun_range: float = float(wd.range) + 9.144
        var is_taser: bool = int(wd.kind) == DL.WeaponKind.TASER
        # 1) 墙区间 (已按 enter 排序), 相邻区间合并
        var list: Array = []
        for w in map.world.bullet_walls(origin, dir, gun_range):
                if list.size() > 0 and w.enter_frac <= (list[-1].exit + 1e-5):
                        var prev: Dictionary = list[-1]
                        if w.exit_frac > prev.exit:
                                prev.exit = w.exit_frac
                                prev.exit_surface = w.exit_surface
                                prev.exit_flags = w.exit_flags
                        prev.contents |= w.contents
                else:
                        list.append({"enter": w.enter_frac, "exit": w.exit_frac,
                                "entry_surface": w.enter_surface, "exit_surface": w.exit_surface,
                                "contents": w.contents, "entry_flags": w.enter_flags, "exit_flags": w.exit_flags,
                                "player": null, "region": DL.HitRegion.CHEST})
        # 2) 玩家命中盒 (包括队友 — 队友挡枪)
        for q in players:
                var q2: DLPlayer = q
                if not q2.alive() or q2.id == shooter.id:
                        continue
                var hb := DLHitboxes.ray_player(q2, origin, dir, gun_range)
                if hb.hit:
                        list.append({"enter": hb.dist, "exit": hb.exit, "entry_surface": -1,
                                "exit_surface": -1, "contents": 1, "entry_flags": 0, "exit_flags": 0,
                                "player": q2, "region": hb.region})
        list.sort_custom(func(a, b) -> bool: return a.enter < b.enter)
        # 3) 逐段推进
        var damage: float = float(wd.damage)
        var cumulative := [0.0]
        var num6 := 0.0          # 已推进距离
        var num7 := 0            # 穿透层数
        var flag := false        # 已命中
        var flesh := ["flesh", 70, 0.9, 0.5]
        for item in list:
                if item.exit <= num6 + 0.0001:
                        continue
                var num8: float = maxf(num6, item.enter)
                var num9: float = gun_range / 0.0254 - cumulative[0]
                var num10: float = (num8 - num6) / 0.0254 / num9
                if num9 <= 0.0 or num10 >= 1.0:
                        break
                damage = DLBallistic.advance(cumulative, num9, num10, damage, float(wd.range_modifier))
                num6 = num8
                if damage < 1.0:
                        break
                var q2: DLPlayer = item.player
                if q2 != null:
                        if q2.team == shooter.team:
                                if not flag:
                                        flag = true
                                break
                        if not flag:
                                flag = true
                        _apply_damage(shooter, q2, wd, damage, item.region, num7 > 0)
                else:
                        if not flag:
                                event_impact.emit(origin + dir * num8, map.world.surface_kind(item.entry_surface), 0)
                if is_taser or float(wd.penetration) <= 0.0 or num7 >= 4 or cumulative[0] > 3000.0:
                        break
                # 穿透: flesh 或墙面 (BulletPenetration.Remaining)
                if q2 != null:
                        damage = DLBallistic.remaining(damage, float(wd.penetration), maxf(0.0, item.exit - num8), flesh, flesh, 1, 0)
                else:
                        var entry_arr := _surface_array(item.entry_surface)
                        var exit_arr := _surface_array(item.exit_surface)
                        damage = DLBallistic.remaining(damage, float(wd.penetration), maxf(0.0, item.exit - num8), entry_arr, exit_arr, item.contents, item.entry_flags)
                        event_impact.emit(origin + dir * (item.exit + 0.01), map.world.surface_kind(item.exit_surface), 0)
                if damage < 1.0:
                        break
                num6 = item.exit
                num7 += 1

func _surface_array(idx: int) -> Array:
        if idx < 0 or idx >= map.world.surfaces.size():
                return ["concrete", 67, 0.5, 0.25]
        var s: Dictionary = map.world.surfaces[idx]
        return [s.name, s.gm, s.pen, s.dmg]

func _apply_damage(attacker: DLPlayer, victim: DLPlayer, wd: Dictionary, damage: float, region: int, penetrated: bool) -> void:
        var armor_left := [victim.armor]
        var dmg := damage
        var region_mul := DLHitboxes.region_multiplier(wd, region)
        dmg *= region_mul
        if region != DL.HitRegion.HEAD:
                dmg = DLBlast.armor(dmg, float(wd.armor_ratio), armor_left)
        else:
                # 头盔
                if victim.helmet:
                        var hl := [victim.armor]
                        dmg = DLBlast.armor(dmg, float(wd.armor_ratio) * 0.75, hl)
                        victim.armor = int(hl[0])
                dmg = maxf(dmg, 1.0)
                victim.armor = int(armor_left[0])
        var final_dmg := DLBallistic.apply_fractional(dmg, victim.damage_accum)
        final_dmg = maxi(0, final_dmg)
        victim.health -= final_dmg
        victim.ai_memory["last_attacker"] = attacker.id
        victim.ai_memory["last_attacker_pos"] = attacker.position
        victim.ai_memory["last_hit_time"] = tick
        attacker.ai_memory["last_victim"] = victim.id
        attacker.ai_memory["last_victim_time"] = tick
        event_hit_feedback.emit(attacker.id, victim.id, region, final_dmg, victim.health <= 0)
        if region == DL.HitRegion.HEAD:
                event_sound.emit("hit_head", victim.position, attacker.id)
        else:
                event_sound.emit("hit_body", victim.position, attacker.id)
        if victim.health <= 0:
                _kill(attacker, victim, 5, region == DL.HitRegion.HEAD, penetrated)

func _kill(attacker: DLPlayer, victim: DLPlayer, weapon: int, headshot: bool, penetrated: bool) -> void:
        victim.health = 0
        victim.deaths += 1
        victim.ai_memory["died_last_round"] = true
        if attacker != null and attacker.id != victim.id:
                attacker.kills += 1
                var wd := DLWeapons.get_weapon(weapon)
                attacker.money = mini(int(RULES.max_money), attacker.money + int(wd.kill_award))
        # TDM 记分
        if mode == Mode.TDM and attacker != null and attacker.id != victim.id:
                score[attacker.team] += 1
        # 掉落主武器（简化: 直接移除）
        _strip_to_pistol(victim)
        event_kill.emit(attacker.id if attacker != null else 255, victim.id, weapon, headshot, penetrated)
        event_sound.emit("death", victim.position, victim.id)

func _noise_event(pos: Vector3, radius: float, source_id: int) -> void:
        ## 枪声传播: 给范围内的敌人写入听觉情报（供 AI 听声辨位）
        var src: DLPlayer = players[source_id] if source_id < players.size() else null
        for p in players:
                var q: DLPlayer = p
                if q == null or not q.alive() or q.id == source_id:
                        continue
                if src != null and q.team == src.team:
                        continue
                if q.position.distance_to(pos) <= radius:
                        q.ai_memory["heard_pos"] = pos
                        q.ai_memory["heard_time"] = tick
        event_sound.emit("noise", pos, source_id)

# ---------------- 投掷物 ----------------
func _step_grenade_throw(p: DLPlayer, cmd: Dictionary) -> void:
        if not DLWeapons.is_grenade(p.gun) or p.ammo[p.gun] <= 0:
                return
        if (cmd.buttons & DL.B_FIRE) == 0:
                if p.grenade_state == 1:
                        p.grenade_state = 0
                return
        if p.grenade_state == 0:
                p.grenade_state = 1
                event_sound.emit("pin_pull", p.position, p.id)
                return
        # 松开瞬间投掷在 _release 处理: 这里持续按住 → 拉环状态
        # 简化: 按住 0.25s 后自动投出
        if p.grenade_state == 1:
                p.ai_memory["grenade_hold"] = float(p.ai_memory.get("grenade_hold", 0.0)) + DL.DT
                if float(p.ai_memory.get("grenade_hold", 0.0)) > 0.2:
                        _throw_grenade(p, cmd, 1.0)

func _release_grenade(p: DLPlayer, cmd: Dictionary, strength: float) -> void:
        if p.grenade_state == 1:
                _throw_grenade(p, cmd, strength)

func _throw_grenade(p: DLPlayer, cmd: Dictionary, strength: float) -> void:
        var wd := DLWeapons.get_weapon(p.gun)
        p.ammo[p.gun] -= 1
        p.grenade_state = 0
        p.ai_memory["grenade_hold"] = 0.0
        var dir := DL.aim(cmd.yaw, cmd.pitch + 8.0)  # 上抛 8°
        var vel: float = 24.4 * strength * float(wd.throw_velocity) if float(wd.throw_velocity) > 0.0 else 24.4 * strength
        if float(wd.throw_velocity) <= 0.0:
                vel = 24.4 * strength
        var g := {
                "id": tick * 16 + p.id, "gun": p.gun, "owner": p.id, "phase": DL.GrenadePhase.FLYING,
                "position": p.eye() + dir * 0.3, "velocity": dir * vel, "age": 0.0, "left": 0.0,
                "bounces": 0, "next_touch_damage": 0.0, "thrower_pos": p.position,
        }
        grenades.append(g)
        p.ai_memory["thrown_gun"] = p.gun
        event_sound.emit("throw", p.position, p.id)
        # 切回武器
        if p.ammo[p.gun] <= 0:
                p.take(p.gun)
        p.gun = p.best_gun()

func _step_grenades() -> void:
        for g in grenades:
                g.age += DL.DT
                match int(g.phase):
                        DL.GrenadePhase.FLYING:
                                g.velocity.y -= DL.GRAVITY * DL.DT
                                var delta: Vector3 = g.velocity * DL.DT
                                var speed := delta.length()
                                var r := map.ray_cast(g.position, delta.normalized(), speed + 0.1)
                                if r.hit and r.dist <= speed:
                                        g.position += delta.normalized() * maxf(0.0, r.dist - 0.05)
                                        var n := _bounce_normal(g, delta)
                                        var damp := 0.45
                                        g.velocity = (g.velocity - n * (2.0 * g.velocity.dot(n))) * damp
                                        g.bounces += 1
                                        event_sound.emit("bounce", g.position, int(g.owner))
                                        _on_grenade_impact(g)
                                else:
                                        g.position += delta
                                # 引信
                                var wd := DLWeapons.get_weapon(int(g.gun))
                                match String(wd.key):
                                        "hegrenade":
                                                if g.age >= 1.7:
                                                        _explode_he(g)
                                        "flashbang":
                                                if g.age >= 1.6:
                                                        _explode_flash(g)
                                        "smokegrenade":
                                                if g.bounces >= 1 and g.velocity.length() < 1.0 or g.age >= 3.5:
                                                        _start_smoke(g)
                                        "molotov", "incgrenade":
                                                if g.bounces >= 1:
                                                        _start_fire(g)
                                        "decoy":
                                                if g.bounces >= 1 and g.velocity.length() < 1.0:
                                                        g.phase = DL.GrenadePhase.DECOY
                                                        g.left = 15.0
                        DL.GrenadePhase.DECOY:
                                g.left -= DL.DT
                                if fmod(g.age, 0.8) < DL.DT:
                                        event_sound.emit("decoy_shot", g.position, int(g.owner))
                                        _noise_event(g.position, 40.0, int(g.owner))
                                if g.left <= 0.0:
                                        g.phase = DL.GrenadePhase.BLAST
                                        event_grenade.emit("remove", g)
                        DL.GrenadePhase.SMOKE:
                                g.left -= DL.DT
                                if g.left <= 0.0:
                                        event_grenade.emit("smoke_end", g)
                                        event_grenade.emit("remove", g)
                        DL.GrenadePhase.BURNING:
                                g.left -= DL.DT
                                if fmod(g.age, 0.25) < DL.DT:
                                        _fire_damage(g)
                                if g.left <= 0.0:
                                        event_grenade.emit("fire_end", g)
                                        event_grenade.emit("remove", g)
                        DL.GrenadePhase.BLAST:
                                event_grenade.emit("remove", g)
        grenades = grenades.filter(func(g2): return int(g2.phase) != DL.GrenadePhase.BLAST or false)

func _bounce_normal(g: Dictionary, delta: Vector3) -> Vector3:
        var r := map.ray_cast(g.position, delta.normalized(), delta.length() + 0.2)
        if r.hit:
                # 找碰撞面法线: 反向探测
                var probe: Vector3 = g.position + delta.normalized() * maxf(0.05, r.dist - 0.02)
                var back := map.ray_cast(probe, -delta.normalized(), 0.4)
                if back.hit:
                        # 粗略: 用地面/墙轴判定
                        return Vector3.UP if probe.y < 0.05 else _axis_normal(delta)
        return Vector3.UP

func _axis_normal(delta: Vector3) -> Vector3:
        var a := Vector3(absf(delta.x), absf(delta.y), absf(delta.z))
        if a.y >= a.x and a.y >= a.z:
                return Vector3.UP if delta.y < 0 else Vector3.DOWN
        if a.x >= a.z:
                return Vector3(-signf(delta.x), 0, 0)
        return Vector3(0, 0, -signf(delta.z))

func _on_grenade_impact(g: Dictionary) -> void:
        var wd := DLWeapons.get_weapon(int(g.gun))
        match String(wd.key):
                "molotov", "incgrenade":
                        _start_fire(g)
                _:
                        pass

func _explode_he(g: Dictionary) -> void:
        g.phase = DL.GrenadePhase.BLAST
        event_grenade.emit("explosion", g)
        event_sound.emit("explosion", g.position, int(g.owner))
        var radius := 10.6  # ~350u
        var base_damage: float = float(DLWeapons.get_weapon(int(g.gun)).damage)
        var thrower: DLPlayer = players[int(g.owner)] if int(g.owner) < players.size() else null
        for p in players:
                var q: DLPlayer = p
                if not q.alive():
                        continue
                if not DLBlast.candidate(g.position, radius, q.position, q.height(), 0.4064):
                        continue
                var closest := q.position + Vector3(0, clampf(g.position.y, 0.0, q.height()), 0)
                var dist: float = (closest - Vector3(g.position)).length()
                # 遮挡衰减
                var exposure := 1.0
                if not map.visible(g.position + Vector3(0, 0.2, 0), closest):
                        exposure = 0.4
                var dmg := DLBlast.damage(base_damage, radius, dist, exposure)
                if dmg < 1.0:
                        continue
                var armor_left := [q.armor]
                dmg = DLBlast.armor(dmg, 0.57, armor_left)
                q.armor = int(armor_left[0])
                q.health -= int(maxf(0.0, dmg))
                q.ai_memory["last_attacker"] = int(g.owner)
                q.ai_memory["last_attacker_pos"] = Vector3(g.thrower_pos)
                event_hit_feedback.emit(int(g.owner), q.id, DL.HitRegion.CHEST, int(dmg), q.health <= 0)
                if q.health <= 0:
                        _kill(thrower, q, int(g.gun), false, false)

func _explode_flash(g: Dictionary) -> void:
        g.phase = DL.GrenadePhase.BLAST
        event_grenade.emit("flash", g)
        event_sound.emit("flashbang", g.position, int(g.owner))
        for p in players:
                var q: DLPlayer = p
                if not q.alive():
                        continue
                var eye := q.eye()
                var to_blast: Vector3 = g.position - eye
                var dist := to_blast.length()
                if dist > 25.0:
                        continue
                if not map.visible(eye, g.position):
                        continue
                var look := DL.aim(q.yaw, q.pitch)
                var facing := clampf(look.dot(-to_blast.normalized()), -1.0, 1.0)
                var blind := 0.0
                if facing > 0.4:
                        blind = 3.0 * facing * (1.0 - dist / 30.0)
                elif facing > -0.5:
                        blind = 1.2 * (1.0 - dist / 25.0)
                if blind > q.flash_left:
                        q.flash_left = blind
                        q.flash_peak = blind
                        q.flash_start_tick = tick

func _start_smoke(g: Dictionary) -> void:
        if int(g.phase) != DL.GrenadePhase.FLYING:
                return
        g.phase = DL.GrenadePhase.SMOKE
        g.left = 18.0
        _smokes.append({"pos": Vector3(g.position), "radius": 3.5, "left": 18.0})
        event_grenade.emit("smoke_start", g)
        event_sound.emit("smoke_pop", g.position, int(g.owner))

func _start_fire(g: Dictionary) -> void:
        if int(g.phase) != DL.GrenadePhase.FLYING:
                return
        g.phase = DL.GrenadePhase.BURNING
        g.left = 7.0
        event_grenade.emit("fire_start", g)
        event_sound.emit("fire_ignite", g.position, int(g.owner))

func _fire_damage(g: Dictionary) -> void:
        var radius := 3.2
        for p in players:
                var q: DLPlayer = p
                if not q.alive():
                        continue
                var closest := Vector3(q.position.x, clampf(g.position.y, q.position.y, q.position.y + q.height()), q.position.z)
                if (closest - Vector3(g.position)).length() <= radius:
                        q.health -= 8
                        q.ai_memory["burning"] = tick
                        event_hit_feedback.emit(int(g.owner), q.id, DL.HitRegion.LEGS, 8, q.health <= 0)
                        event_sound.emit("fire_pain", q.position, int(g.owner))
                        if q.health <= 0:
                                _kill(players[int(g.owner)] if int(g.owner) < players.size() else q, q, int(g.gun), false, false)

func smoke_between(from: Vector3, to: Vector3) -> float:
        ## 返回视线被烟雾遮挡的长度（米），用于 AI 感知
        var worst := 0.0
        for s in _smokes:
                var len := DLBlast.smoke_blocking_length(float(s.radius), s.pos, from, to)
                if len > worst:
                        worst = len
        return worst

# ---------------- 炸弹 ----------------
func _step_bomb() -> void:
        match int(bomb.stage):
                DL.BombStage.CARRIED:
                        if bomb.carrier < players.size():
                                var carrier: DLPlayer = players[int(bomb.carrier)]
                                if not carrier.alive():
                                        bomb.stage = DL.BombStage.DROPPED
                                        bomb.position = carrier.position
                                        bomb.carrier = 255
                                else:
                                        carrier.bomb_equipped = true
                DL.BombStage.DROPPED:
                        for p in players:
                                var q: DLPlayer = p
                                if q.alive() and q.team == 1 and q.position.distance_to(bomb.position) < 1.2:
                                        bomb.stage = DL.BombStage.CARRIED
                                        bomb.carrier = q.id
                                        break
                DL.BombStage.PLANTED:
                        bomb.time_left -= DL.DT
                        if bomb.time_left <= 0.0:
                                _bomb_explode()
                                return
                        # 拆弹
                        for p in players:
                                var q: DLPlayer = p
                                if q.alive() and q.team == 0:
                                        var cmd: Dictionary = commands[q.id] if q.id < commands.size() else _idle_command(q)
                                        if (cmd.buttons & DL.B_USE) != 0 and q.position.distance_to(bomb.position) < 1.6:
                                                bomb.progress += DL.DT
                                                bomb.actor = q.id
                                                if fmod(bomb.progress, 0.5) < DL.DT:
                                                        event_sound.emit("defuse_tick", bomb.position, q.id)
                                                if bomb.progress >= (RULES.kit_time if q.defuse_kit else RULES.defuse_time):
                                                        bomb.stage = DL.BombStage.DEFUSED
                                                        event_bomb.emit("defused", int(bomb.site), bomb.position, q.id)
                                                        _end_round(0, "bomb_defused")
                                                        return
                                        else:
                                                if bomb.actor == q.id:
                                                        bomb.actor = 255
                                                        bomb.progress = 0.0

func try_plant(p: DLPlayer) -> bool:
        if mode != Mode.DEFUSAL or int(bomb.stage) != DL.BombStage.CARRIED or int(bomb.carrier) != p.id:
                return false
        if p.team != 1 or not p.alive() or phase != DL.RoundPhase.LIVE:
                return false
        var site := map.bomb_site_at(p.position)
        if site == 0:
                return false
        bomb.site = site
        bomb.stage = DL.BombStage.PLANTED
        bomb.position = p.position
        bomb.time_left = RULES.bomb_time
        bomb.carrier = 255
        p.bomb_equipped = false
        p.money = mini(int(RULES.max_money), p.money + 300)
        event_bomb.emit("planted", site, p.position, p.id)
        return true

func _bomb_explode() -> void:
        bomb.stage = DL.BombStage.EXPLODED
        event_bomb.emit("exploded", int(bomb.site), bomb.position, 255)
        event_sound.emit("c4_explode", bomb.position, 255)
        for p in players:
                var q: DLPlayer = p
                if not q.alive():
                        continue
                var d := q.position.distance_to(bomb.position)
                if d < 17.5:
                        q.health -= int(maxf(0.0, 500.0 * (1.0 - d / 17.5)))
                        if q.health <= 0:
                                _kill(null, q, DL.C4, false, false)
        _end_round(1, "bomb_exploded")

# ---------------- 回合流程 ----------------
func _check_round_end() -> void:
        if mode == Mode.WAVE:
                _check_wave()
                return
        if mode == Mode.TDM:
                _check_tdm()
                return
        match int(phase):
                DL.RoundPhase.PREPARE:
                        if phase_left <= 0.0:
                                start_live()
                                event_round.emit(DL.RoundPhase.LIVE, -1, "")
                DL.RoundPhase.LIVE:
                        var ct := alive_count(0)
                        var t := alive_count(1)
                        if t == 0 and int(bomb.stage) != DL.BombStage.PLANTED:
                                _end_round(0, "t_eliminated")
                        elif ct == 0:
                                _end_round(1, "ct_eliminated")
                        elif phase_left <= 0.0:
                                _end_round(0, "time_out")
                DL.RoundPhase.RESULT:
                        if phase_left <= 0.0:
                                round_num += 1
                                if score[0] >= 16 or score[1] >= 16:
                                        match_over = true
                                        winner = 0 if score[0] > score[1] else 1
                                        event_round.emit(DL.RoundPhase.MATCH_OVER, winner, "match_over")
                                else:
                                        round_reset()

func _end_round(win_team: int, reason: String) -> void:
        if phase == DL.RoundPhase.RESULT:
                return
        phase = DL.RoundPhase.RESULT
        phase_left = RULES.result_time
        score[win_team] += 1
        # 经济
        for p in players:
                var q: DLPlayer = p
                var win: bool = q.team == win_team
                if win:
                        loss_streak[p.team] = 0
                        p.money = mini(int(RULES.max_money), p.money + (3500 if reason == "bomb_defused" else 3250))
                else:
                        loss_streak[1 - p.team] = loss_streak[1 - p.team] + 1 if false else loss_streak[p.team] + 1
                        loss_streak[p.team] = mini(4, loss_streak[p.team] + 1)
                        var loss_bonus := 1400 + 500 * mini(4, loss_streak[p.team] - 1)
                        p.money = mini(int(RULES.max_money), p.money + loss_bonus)
        event_round.emit(DL.RoundPhase.RESULT, win_team, reason)

func _check_tdm() -> void:
        if phase == DL.RoundPhase.PREPARE and phase_left <= 0.0:
                start_live()
        # 无回合制: 死亡 5s 重生, 先到 40 杀
        for p in players:
                if not p.alive():
                        p.ai_memory["respawn_timer"] = float(p.ai_memory.get("respawn_timer", 0.0)) + DL.DT
                        if float(p.ai_memory.get("respawn_timer", 0.0)) >= 5.0:
                                p.ai_memory["respawn_timer"] = 0.0
                                p.ai_memory["died_last_round"] = false
                                p.reset_for_round(spawn_point(p.team, p.id))
                                p.yaw = spawn_yaw(p.team, p.id)
                                p.health = 100
                if p.money < RULES.max_money:
                        pass
        if score[0] >= 40 or score[1] >= 40 or tick * DL.DT > 600.0:
                match_over = true
                winner = 0 if score[0] > score[1] else 1
                event_round.emit(DL.RoundPhase.MATCH_OVER, winner, "match_over")

func _check_wave() -> void:
        if phase == DL.RoundPhase.PREPARE and phase_left <= 0.0:
                start_live()
                event_round.emit(DL.RoundPhase.LIVE, -1, "")
        # 玩家小队 vs 增强波次
        if alive_count(0) == 0:
                match_over = true
                winner = 1
                event_round.emit(DL.RoundPhase.MATCH_OVER, 1, "wave_lost")
                return
        if alive_count(1) == 0 and phase == DL.RoundPhase.LIVE:
                wave += 1
                phase = DL.RoundPhase.PREPARE
                phase_left = 5.0
                # 新波次: 敌人 +1
                var t_needed := 3 + wave
                var t_idx := 0
                for p in players:
                        if p.team == 1:
                                t_idx += 1
                                if not p.alive():
                                        p.reset_for_round(spawn_point(1, t_idx))
                                        p.yaw = spawn_yaw(1, t_idx)
                                        p.health = 100
                                        p.ai_memory["died_last_round"] = false
                event_round.emit(DL.RoundPhase.PREPARE, -1, "wave_%d" % wave)

func alive_time_sec(p: DLPlayer) -> float:
        return p.alive_time
