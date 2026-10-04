class_name DLBotAI extends RefCounted
## 战术 AI: 行为树 + 效用打分 + 小队黑板共享（用户增强需求）
## 输出 Command 交给 DLMatch；感知含 FOV/烟雾遮挡/听声

var player: DLPlayer
var match_ref: DLMatch
var blackboard: Dictionary    # 每队共享 {last_known: {id: Vector3}, threat: Vector3, calls: []}
var path: PackedVector3Array = PackedVector3Array()
var path_idx := 0
var stuck_time := 0.0
var goal := Vector3.ZERO
var goal_site := -1
var think_accum := 0.0
var aim_target := Vector3.ZERO
var aim_lock := 0.0
var reaction_delay := 0.0
var skill := 0.5              # 0..1 由难度设置
var current_action := "patrol"
var strafe_dir := 0.0
var strafe_timer := 0.0
var hold_pos := Vector3.ZERO
var hold_timer := 0.0

const FOV_COS := 0.34         # ~70° 半角
const AIM_SPEED := 6.0        # rad/s 转向
const REACT_BASE := 0.28      # 基础反应时间

func _init(p: DLPlayer, m: DLMatch, bb: Dictionary, p_skill := 0.5) -> void:
        player = p
        match_ref = m
        blackboard = bb
        skill = p_skill
        reaction_delay = REACT_BASE + (1.0 - skill) * 0.35
        if not blackboard.has("last_known"):
                blackboard["last_known"] = {}
                blackboard["under_fire"] = {}
                blackboard["flank_calls"] = []

func think(dt: float) -> Dictionary:
        var cmd := {"x": 0.0, "z": 0.0, "yaw": player.yaw, "pitch": player.pitch, "buttons": 0,
                "weapon": player.gun, "buy": 0}
        if not player.alive():
                return cmd
        var eye := player.eye()
        # ---- 感知 ----
        # 性能: 完整视野扫描（射线+烟雾检测）15Hz 错峰（每 4 tick），中间帧复用缓存。
        if match_ref.tick % 4 == player.id % 4:
                _scan_cache = _scan_enemies(eye)
        else:
                _scan_cache = _scan_cache.filter(func(q): return q.alive())
        var visible_enemies: Array = _scan_cache
        var target: DLPlayer = null
        if visible_enemies.size() > 0:
                visible_enemies.sort_custom(func(a, b): return a.position.distance_squared_to(eye) < b.position.distance_squared_to(eye))
                target = visible_enemies[0]
                blackboard["last_known"][target.id] = target.position
                blackboard["threat"] = target.position
                blackboard["threat_time"] = match_ref.tick
        # 记忆衰减
        var threat_fresh: bool = blackboard.has("threat_time") and match_ref.tick - int(blackboard["threat_time"]) < 128
        # 听声辨位: 队友/自己听到枪声 → 更新威胁
        var mem: Dictionary = player.ai_memory
        if mem.has("heard_time") and match_ref.tick - int(mem.get("heard_time", 0)) < 32:
                blackboard["threat"] = mem["heard_pos"]
                blackboard["threat_time"] = match_ref.tick
                mem["heard_time"] = 0  # 消费一次
        if mem.has("last_hit_time") and match_ref.tick - int(mem.get("last_hit_time", 0)) < 16:
                if mem.has("last_attacker_pos"):
                        blackboard["under_fire"][player.id] = mem["last_attacker_pos"]
                        if not visible_enemies.has(match_ref.players[int(mem.get("last_attacker", 255))] if int(mem.get("last_attacker", 255)) < match_ref.players.size() else null):
                                # 被打了但没看见 → 转向威胁
                                aim_target = mem["last_attacker_pos"]
                                aim_lock = 0.0
        # ---- 效用评估（每 0.2s 重新决策）----
        think_accum -= dt
        if think_accum <= 0.0:
                think_accum = 0.2
                current_action = _choose_action(target, threat_fresh)
        # ---- 行为 ----
        match current_action:
                "engage":
                        _do_engage(cmd, target, eye)
                "take_cover":
                        _do_take_cover(cmd, eye)
                "retreat":
                        _do_retreat(cmd, eye)
                "investigate":
                        _do_investigate(cmd, eye)
                "flank":
                        _do_flank(cmd, eye)
                "plant":
                        cmd.buttons |= DL.B_USE
                        _do_move_to(cmd, eye, _plant_spot(), 0.0)
                        if match_ref.map.bomb_site_at(player.position) != 0 and match_ref.try_plant(player):
                                current_action = "hold_site"
                "defuse":
                        cmd.buttons |= DL.B_USE
                "hold_site", "patrol", "hold":
                        _do_patrol(cmd, eye)
        # 目标可见时始终瞄向目标
        if target != null:
                aim_target = target.eye()
                aim_lock = minf(aim_lock + dt * (0.7 + skill), 2.0)
                _apply_aim(cmd, aim_target, eye, dt, true)
        else:
                aim_lock = maxf(0.0, aim_lock - dt * 2.0)
                if current_action != "engage" and aim_target != Vector3.ZERO:
                        _apply_aim(cmd, aim_target, eye, dt, false)
        # 换弹逻辑: 空仓必换, 无目标且弹匣<35% 顺手换
        var wd := DLWeapons.get_weapon(player.gun)
        if DLWeapons.is_firearm(player.gun):
                if player.ammo[player.gun] == 0:
                        cmd.buttons |= DL.B_RELOAD
                elif player.ammo[player.gun] < int(wd.magazine) * 35 / 100 and target == null and player.reserve[player.gun] > 0:
                        cmd.buttons |= DL.B_RELOAD
        return cmd

func _scan_enemies(eye: Vector3) -> Array:
        var out: Array = []
        var look := DL.aim(player.yaw, player.pitch)
        for p in match_ref.players:
                var q: DLPlayer = p
                if not q.alive() or q.team == player.team:
                        continue
                var to := q.eye() - eye
                var dist := to.length()
                if dist > 55.0:
                        continue
                var dirn := to / dist
                var in_fov := look.dot(dirn) > FOV_COS
                var heard: bool = q.velocity.length() > 4.0 and dist < 14.0
                if not in_fov and not heard:
                        continue
                # 视线 + 烟雾遮挡
                if not match_ref.map.visible(eye, q.eye() + Vector3(0, -0.1, 0)):
                        continue
                if match_ref.smoke_between(eye, q.eye()) > dist * 0.6:
                        continue
                out.append(q)
        return out

func _choose_action(target: DLPlayer, threat_fresh: bool) -> String:
        var hp_frac := float(player.health) / 100.0
        var wd := DLWeapons.get_weapon(player.gun)
        var ammo_frac: float = float(player.ammo[player.gun]) / maxf(1.0, float(wd.magazine))
        # 炸弹任务优先
        if match_ref.mode == DLMatch.Mode.DEFUSAL:
                if player.team == 1 and int(match_ref.bomb.stage) == DL.BombStage.CARRIED and int(match_ref.bomb.carrier) == player.id:
                        if match_ref.map.bomb_site_at(player.position) != 0:
                                return "plant"
                if player.team == 0 and int(match_ref.bomb.stage) == DL.BombStage.PLANTED:
                        if player.position.distance_to(match_ref.bomb.position) < 1.6:
                                return "defuse"
        # 效用打分
        var u_engage := 0.0
        var u_cover := 0.0
        var u_retreat := 0.0
        var u_invest := 0.0
        var u_flank := 0.0
        if target != null:
                u_engage = 6.0 + skill * 3.0
                u_engage *= ammo_frac + 0.3
                u_cover = (1.0 - hp_frac) * 4.0 + (1.0 - ammo_frac) * 5.0
                u_retreat = (1.0 - hp_frac) * 7.0 if hp_frac < 0.35 else 0.0
                u_flank = 2.0 if randf() < 0.02 + skill * 0.03 else 0.0
        else:
                u_cover = (1.0 - hp_frac) * 3.0 if threat_fresh else 0.0
                u_invest = 4.0 if threat_fresh else 0.0
        u_invest += 1.0 if current_action == "investigate" else 0.0
        var scores := {"engage": u_engage, "take_cover": u_cover, "retreat": u_retreat,
                "investigate": u_invest, "flank": u_flank,
                "patrol": 1.5 + (2.5 if current_action == "patrol" else 0.0),
                "hold_site": 2.0 if current_action == "hold_site" else 0.0}
        if match_ref.mode == DLMatch.Mode.DEFUSAL and player.team == 0 and int(match_ref.bomb.stage) == DL.BombStage.PLANTED:
                var d := player.position.distance_to(match_ref.bomb.position)
                if d < 20.0:
                        scores["defuse"] = 10.0 - d * 0.3
        # 掩体不足时降低 take_cover 权重
        if u_cover > 0.0 and _nearest_cover(player.position) == Vector3.ZERO:
                scores["take_cover"] = 0.0
        var best := "patrol"
        var best_u := -1.0
        for k in scores:
                if scores[k] > best_u:
                        best_u = scores[k]
                        best = k
        return best

func _nearest_cover(from: Vector3) -> Vector3:
        var best := Vector3.ZERO
        var best_d := INF
        for cp in match_ref.cover_points:
                var pos: Vector3 = cp.pos
                # 掩体点应朝向威胁方向才算有用（简化: 距离 + 不被看见）
                var d := pos.distance_squared_to(from)
                if d < best_d and match_ref.map.clear_at(pos):
                        var hidden := true
                        for q in match_ref.players:
                                var q2: DLPlayer = q
                                if q2.alive() and q2.team != player.team:
                                        if match_ref.map.visible(q2.eye(), pos + Vector3(0, 1.2, 0)):
                                                hidden = false
                                                break
                        if hidden:
                                best_d = d
                                best = pos
        return best

func _do_engage(cmd: Dictionary, target: DLPlayer, eye: Vector3) -> void:
        if target == null:
                return
        var dist := target.position.distance_to(player.position)
        # 站立开火 + 侧移抖动
        strafe_timer -= 0.2
        if strafe_timer <= 0.0:
                strafe_timer = 0.4 + randf() * 0.6
                strafe_dir = [-1.0, 0.0, 1.0][randi() % 3]
        cmd.x = strafe_dir
        # 距离管理: 太近后退, 太远前进
        var fwd := DL.aim(player.yaw, 0.0)
        if dist > 22.0:
                cmd.z = 1.0
        elif dist < 6.0:
                cmd.z = -1.0
        # 换弹时找掩体
        var wd := DLWeapons.get_weapon(player.gun)
        if player.ammo[player.gun] == 0 and player.reserve[player.gun] > 0:
                cmd.buttons |= DL.B_RELOAD
                var cover := _nearest_cover(player.position)
                if cover != Vector3.ZERO:
                        _do_move_to(cmd, eye, cover, 0.0)
        # 开火判定: 锁定时间够 + 反应延迟过
        if aim_lock >= reaction_delay and _aim_close_enough():
                cmd.buttons |= DL.B_FIRE

func _do_take_cover(cmd: Dictionary, eye: Vector3) -> void:
        var cover := _nearest_cover(player.position)
        if cover == Vector3.ZERO:
                _do_retreat(cmd, eye)
                return
        _do_move_to(cmd, eye, cover, 0.0)
        if player.position.distance_to(cover) < 0.8:
                hold_timer += 0.2
                var wd := DLWeapons.get_weapon(player.gun)
                if player.ammo[player.gun] < int(wd.magazine) and player.reserve[player.gun] > 0:
                        cmd.buttons |= DL.B_RELOAD
                if hold_timer > 2.0:
                        hold_timer = 0.0
                        current_action = "patrol"

func _do_retreat(cmd: Dictionary, eye: Vector3) -> void:
        var threat_pos: Vector3 = blackboard.get("threat", player.position)
        var away: Vector3 = player.position + (player.position - threat_pos).normalized() * 8.0
        _do_move_to(cmd, eye, away, 0.0)

func _do_investigate(cmd: Dictionary, eye: Vector3) -> void:
        var t: Vector3 = blackboard.get("threat", player.position)
        _do_move_to(cmd, eye, t, 0.0)
        if player.position.distance_to(t) < 2.0:
                blackboard.erase("threat_time")
                current_action = "patrol"

func _do_flank(cmd: Dictionary, eye: Vector3) -> void:
        var t: Vector3 = blackboard.get("threat", player.position)
        # 侧向绕行点
        var side := Vector3(-(t - player.position).z, 0, (t - player.position).x).normalized() * (6.0 if player.id % 2 == 0 else -6.0)
        var flank_pt := t + side
        _do_move_to(cmd, eye, flank_pt, 0.0)
        if player.position.distance_to(flank_pt) < 1.5:
                current_action = "engage"

func _do_patrol(cmd: Dictionary, eye: Vector3) -> void:
        match_ref.mode = match_ref.mode
        if match_ref.mode == DLMatch.Mode.DEFUSAL:
                # T 推包点 / CT 守包点
                if player.team == 1 and int(match_ref.bomb.stage) != DL.BombStage.PLANTED:
                        goal_site = 1 if player.id % 2 == 0 else 2
                        var site := match_ref.map.site_a if goal_site == 1 else match_ref.map.site_b
                        _ensure_path(site + Vector3(2, 0, 2))
                elif player.team == 0:
                        var site := match_ref.map.site_a if player.id % 2 == 0 else match_ref.map.site_b
                        _ensure_path(site + Vector3(1, 0, 1))
                else:
                        _ensure_path(match_ref.map.site_a if goal_site != 2 else match_ref.map.site_b)
        else:
                # TDM/WAVE: 找最近敌人出生方向巡逻
                var target_pos := Vector3.ZERO
                var best_d := INF
                for q in match_ref.players:
                        var q2: DLPlayer = q
                        if q2.alive() and q2.team != player.team:
                                var d: float = q2.position.distance_squared_to(player.position)
                                if d < best_d:
                                        best_d = d
                                        target_pos = q2.position
                if target_pos != Vector3.ZERO:
                        _ensure_path(target_pos)
        _follow_path(cmd)

func _plant_spot() -> Vector3:
        return match_ref.map.site_a if player.id % 2 == 0 else match_ref.map.site_b

func _do_move_to(cmd: Dictionary, eye: Vector3, dest: Vector3, stop_dist: float) -> void:
        _ensure_path(dest)
        _follow_path(cmd)

func _ensure_path(dest: Vector3) -> void:
        if path.size() == 0 or path_idx >= path.size() or dest.distance_to(goal) > 3.0:
                goal = dest
                path = match_ref.map.path(player.position, dest)
                path_idx = 0

func _follow_path(cmd: Dictionary) -> void:
        if path.size() == 0:
                return
        # 跳过已到达的路径点
        while path_idx < path.size():
                var wp := path[path_idx]
                if Vector2(wp.x, wp.z).distance_to(Vector2(player.position.x, player.position.z)) < 1.4:
                        path_idx += 1
                else:
                        break
        if path_idx >= path.size():
                path = PackedVector3Array()
                return
        var wp := path[path_idx]
        var to := wp - player.position
        # 紧贴墙受阻 → 跳过该路径点 (下一路点通常可绕)
        if to.length() > 2.0:
                var flat_to := Vector3(to.x, 0.0, to.z).normalized()
                var probe_t: DLSourceWorld.Trace = match_ref.map.world.sweep(player.position, flat_to * 0.6, 0.4064, player.height(), 1)
                if probe_t.hit and probe_t.fraction < 0.12 and not probe_t.start_solid:
                        path_idx = mini(path_idx + 1, path.size() - 1)
                        wp = path[path_idx]
                        to = wp - player.position
        # 朝向路径点行走（角度转成 x/z 输入）
        var yaw_to := rad_to_deg(atan2(to.x, to.z))
        var rel := wrapf(yaw_to - player.yaw + 180.0, 0.0, 360.0) - 180.0
        # 直接把 yaw 朝路点转（边走边转）
        cmd.yaw = player.yaw + clampf(rel, -AIM_SPEED * 57.3 * DL.DT * 2.0, AIM_SPEED * 57.3 * DL.DT * 2.0)
        cmd.z = 1.0
        if absf(rel) > 60.0:
                cmd.z = 0.2
        # 原版 SourceWorld.Steer: 8 向探测绕障
        var want := Vector3(to.x, 0.0, to.z)
        if want.length() > 0.05:
                var steered: Vector3 = match_ref.map.world.steer(player.position, player.height(), want.normalized() * 1.2)
                if steered.length() > 0.1:
                        var steer_yaw := rad_to_deg(atan2(steered.x, steered.z))
                        var srel := wrapf(steer_yaw - player.yaw + 180.0, 0.0, 360.0) - 180.0
                        cmd.yaw = player.yaw + clampf(srel, -AIM_SPEED * 57.3 * DL.DT * 4.0, AIM_SPEED * 57.3 * DL.DT * 4.0)
        # 脱困: 位置长时间不变 → 跳跃/侧移/重算路径
        var flat_move := Vector2(player.velocity.x, player.velocity.z).length()
        if flat_move < 0.6:
                stuck_time += DL.DT
                if stuck_time > 0.4 and match_ref.map.world.should_jump(player.position, player.height(), player.grounded, want.normalized()):
                        cmd.buttons = int(cmd.buttons) | DL.B_JUMP
                        stuck_time = 0.0
                elif stuck_time > 0.8:
                        cmd.x = 1.0 if (randi() % 2 == 0) else -1.0
                if stuck_time > 2.5:
                        path = PackedVector3Array()
                        stuck_time = 0.0
        else:
                stuck_time = 0.0
        # 遇队友阻挡 → 绕行
        var others: Array = match_ref.players
        var fwd := DL.aim(cmd.yaw, 0.0)
        var probe := DLTrace.players(player, player.position, fwd * 1.2, player.height(), others)
        if probe.hit:
                cmd.x = 1.0 if player.id % 2 == 0 else -1.0

func _apply_aim(cmd: Dictionary, target_pos: Vector3, eye: Vector3, dt: float, shooting: bool) -> void:
        var to := target_pos - eye
        var desired_yaw := rad_to_deg(atan2(to.x, to.z))
        var desired_pitch := rad_to_deg(asin(clampf(to.y / maxf(0.001, to.length()), -1.0, 1.0)))
        # 人体工学: 水平先到, 垂直滞后
        var turn_rate: float = AIM_SPEED * (1.0 + skill) * 57.2958
        var ny := player.yaw + clampf(wrapf(desired_yaw - player.yaw + 180.0, 0.0, 360.0) - 180.0, -turn_rate * dt, turn_rate * dt)
        var np := player.pitch + clampf(desired_pitch - player.pitch, -turn_rate * 0.6 * dt, turn_rate * 0.6 * dt)
        # 神经网络微操叠加（若已训练）
        var adjust := _nn_adjust()
        cmd.yaw = ny + adjust.x
        cmd.pitch = clampf(np + adjust.y, -89.0, 89.0)

func _aim_close_enough() -> bool:
        # 瞄准误差 < 武器精度容差才开枪
        var wd := DLWeapons.get_weapon(player.gun)
        var tolerance: float = 2.5 - skill * 1.2 + float(wd.inaccuracy_stand) * 57.3
        var target_pos := aim_target + Vector3(0, 0.1, 0)
        var to := target_pos - player.eye()
        var desired_yaw := rad_to_deg(atan2(to.x, to.z))
        var dy := absf(wrapf(desired_yaw - player.yaw + 180.0, 0.0, 360.0) - 180.0)
        return dy < tolerance

## 预留: 神经网络微操策略（PPO 训练产物）接入点
var nn_policy: Dictionary = {}
var _nn_cache: Vector2 = Vector2.ZERO
var _scan_cache: Array = []
func _nn_adjust() -> Vector2:
        if nn_policy.is_empty():
                return Vector2.ZERO
        # 性能: 瞄准微操 8Hz 足够（人类手感级别），缓存中间帧结果。
        # 每 bot 按 id 错峰，避免同帧 9 个 bot 集中推理。
        if match_ref.tick % 8 != player.id % 8:
                return _nn_cache
        # 前向传播: obs -> hidden(tanh) -> out(tanh) * 1.5°
        var obs := _nn_obs()
        var w1: Array = nn_policy.get("w1", [])
        var b1: Array = nn_policy.get("b1", [])
        var w2: Array = nn_policy.get("w2", [])
        var b2: Array = nn_policy.get("b2", [])
        if w1.is_empty():
                return Vector2.ZERO
        var h := b1.duplicate()
        for j in b1.size():
                var s: float = h[j]
                for i in obs.size():
                        s += obs[i] * float(w1[i][j])
                h[j] = tanh(s)
        var out := b2.duplicate()
        for k in b2.size():
                var s2: float = out[k]
                for j in h.size():
                        s2 += h[j] * float(w2[j][k])
                out[k] = tanh(s2)
        _nn_cache = Vector2(out[0], out[1]) * 1.5
        return _nn_cache

func _nn_obs() -> Array:
        var obs: Array = []
        var t := aim_target
        if t == Vector3.ZERO:
                obs = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        else:
                var to := t - player.eye()
                var desired_yaw := rad_to_deg(atan2(to.x, to.z))
                var yaw_err := wrapf(desired_yaw - player.yaw + 180.0, 0.0, 360.0) - 180.0
                var pitch_err := rad_to_deg(asin(clampf(to.y / maxf(0.001, to.length()), -1.0, 1.0))) - player.pitch
                obs = [clampf(yaw_err / 30.0, -1, 1), clampf(pitch_err / 30.0, -1, 1),
                        clampf(player.velocity.length() / 6.0, 0, 1), 1.0 if player.grounded else 0.0,
                        clampf(aim_lock / 2.0, 0, 1), clampf(float(player.health) / 100.0, 0, 1)]
        return obs
