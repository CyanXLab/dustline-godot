extends Node3D
## 主入口: 菜单 → 对局循环（64Hz 确定性模拟）+ 表现同步 + Bot AI 驱动

var match_sim: DLMatch
var world: Node3D
var hud: GameHUD
var bots: Array = []
var team_blackboards: Dictionary = {}
var accum := 0.0
var playing := false
var mouse_sensitivity := 0.0022
var camera: Camera3D
var viewmodel: DLViewModel
var _ai_last_ms: int = 0
var bob_time := 0.0
var recoil_visual := Vector2.ZERO
var menu: Control
var difficulty := 0.55
var autotest_mode := -1
var autotest_until_tick := 0

const SIM_HZ := 64.0
const BUY_ITEMS := [
        ["AK-47", 2700], ["M4A4", 3100], ["AWP", 4750], ["SSG 08", 1700],
        ["MP5-SD", 1500], ["P90", 2350], ["高爆手雷", 300], ["烟雾弹", 300],
        ["闪光弹", 200], ["防弹衣", 650], ["防弹衣+头盔", 1000], ["拆弹器", 400],
]

func _ready() -> void:
        world = Node3D.new()
        add_child(world)
        if OS.get_environment("DL_MIN") != "1":
                hud = GameHUD.new()
                add_child(hud)
                _build_menu()
        # 自动化测试: --autotest=TDM|DEFUSAL|WAVE
        for arg in OS.get_cmdline_user_args():
                if arg.begins_with("--autotest="):
                        var mode_name: String = arg.get_slice("=", 1)
                        var mode: int = DLMatch.Mode.DEFUSAL
                        if mode_name == "TDM": mode = DLMatch.Mode.TDM
                        elif mode_name == "WAVE": mode = DLMatch.Mode.WAVE
                        autotest_mode = mode
                        autotest_until_tick = 64 * 35
                        call_deferred("_start", mode)
                        break

func _build_menu() -> void:
        menu = Control.new()
        menu.set_anchors_preset(Control.PRESET_FULL_RECT)
        var cl := CanvasLayer.new()
        add_child(cl)
        cl.add_child(menu)
        menu.set_anchors_preset(Control.PRESET_FULL_RECT)
        var bg := ColorRect.new()
        bg.color = Color(0.08, 0.09, 0.1, 0.95)
        bg.set_anchors_preset(Control.PRESET_FULL_RECT)
        menu.add_child(bg)
        var title := Label.new()
        title.text = "DUSTLINE"
        title.add_theme_font_size_override("font_size", 72)
        title.add_theme_color_override("font_color", Color(0.9, 0.85, 0.6))
        title.set_anchors_preset(Control.PRESET_CENTER_TOP)
        title.position = Vector2(-160, 100)
        menu.add_child(title)
        var sub := Label.new()
        sub.text = "Godot 4.7 完整移植版 · 拆弹 / 团队死斗 / 波次生存"
        sub.add_theme_font_size_override("font_size", 20)
        sub.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
        sub.set_anchors_preset(Control.PRESET_CENTER_TOP)
        sub.position = Vector2(-260, 190)
        menu.add_child(sub)
        var vbox := VBoxContainer.new()
        vbox.set_anchors_preset(Control.PRESET_CENTER)
        vbox.position = Vector2(-130, -60)
        vbox.add_theme_constant_override("separation", 14)
        menu.add_child(vbox)
        _add_menu_button(vbox, "拆弹模式  5v5", func(): _start(DLMatch.Mode.DEFUSAL))
        _add_menu_button(vbox, "团队死斗  5v5（先到40杀）", func(): _start(DLMatch.Mode.TDM))
        _add_menu_button(vbox, "波次生存（无尽）", func(): _start(DLMatch.Mode.WAVE))
        var diff_row := HBoxContainer.new()
        vbox.add_child(diff_row)
        var diff_label := Label.new()
        diff_label.text = "AI 强度:  "
        diff_label.add_theme_font_size_override("font_size", 18)
        diff_row.add_child(diff_label)
        var slider := HSlider.new()
        slider.min_value = 0.2
        slider.max_value = 1.0
        slider.step = 0.05
        slider.value = difficulty
        slider.custom_minimum_size = Vector2(220, 24)
        slider.value_changed.connect(func(v): difficulty = v)
        diff_row.add_child(slider)
        var hint := Label.new()
        hint.text = "WASD移动 · 左键开火 · 右键瞄准 · R换弹 · B购买 · Tab计分板 · G丢包 · 1/2/3切枪 · 4投掷物 · E下包/拆包"
        hint.add_theme_font_size_override("font_size", 15)
        hint.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
        hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
        hint.position = Vector2(-420, -50)
        menu.add_child(hint)

func _add_menu_button(parent: Node, text: String, cb: Callable) -> void:
        var b := Button.new()
        b.text = text
        b.custom_minimum_size = Vector2(260, 44)
        b.add_theme_font_size_override("font_size", 20)
        b.pressed.connect(func():
                Bank.play_ui("ui_click")
                cb.call())
        parent.add_child(b)

func _start(mode: int) -> void:
        if menu != null and menu.get_parent() != null:
                menu.get_parent().queue_free()
                menu = null
        match_sim = DLMatch.new(mode, 9 if mode != DLMatch.Mode.WAVE else 7)
        match_sim.event_kill.connect(_on_kill)
        match_sim.event_impact.connect(_on_impact)
        match_sim.event_sound.connect(_on_sound)
        match_sim.event_grenade.connect(_on_grenade)
        match_sim.event_bomb.connect(_on_bomb)
        match_sim.event_round.connect(_on_round)
        match_sim.event_hit_feedback.connect(_on_hit_feedback)
        var wb := load("res://src/game/world_builder.gd")
        world = wb.new()
        add_child(world)
        if OS.get_environment("DL_NOWORLD") != "1":
                world.build(match_sim.map)
                for p in match_sim.players:
                        (world as Node3D).spawn_body(p)
        for p in match_sim.players:
                if p.bot:
                        if not team_blackboards.has(p.team):
                                team_blackboards[p.team] = {}
                        var ai := DLBotAI.new(p, match_sim, team_blackboards[p.team], clampf(difficulty + randf_range(-0.12, 0.12), 0.1, 1.0))
                        # 载入 Python 训练的微操瞄准策略 (CEM)
                        if FileAccess.file_exists("res://assets/nn_policy.json"):
                                var nf := FileAccess.open("res://assets/nn_policy.json", FileAccess.READ)
                                var np_data: Dictionary = JSON.parse_string(nf.get_as_text())
                                if np_data.has("w1"):
                                        ai.nn_policy = {"w1": np_data.w1, "b1": np_data.b1, "w2": np_data.w2, "b2": np_data.b2}
                        bots.append(ai)
        if OS.get_environment("DL_MIN") != "1":
                camera = Camera3D.new()
                camera.fov = _source_vfov(90.0)
                camera.attributes = world.cam_attributes
                add_child(camera)
                viewmodel = DLViewModel.new(world.rig_content, match_sim.players[0])
                camera.add_child(viewmodel)
                camera.make_current()
        playing = true
        Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
        Bank.play_ui("round_start")

func _process(delta: float) -> void:
        if not playing or match_sim == null:
                return
        # 自动化测试: 按模拟 tick 计数退出 (帧率无关, headless 下墙钟定时器不可靠)
        if autotest_mode >= 0 and match_sim.tick >= autotest_until_tick:
                var mk := 0
                for pp in match_sim.players:
                        mk += pp.kills
                print("AUTOTEST_DONE kills=", mk, " tick=", match_sim.tick)
                get_tree().quit()
                return
        # 固定 64Hz 模拟步进
        accum += delta
        while accum >= 1.0 / SIM_HZ:
                accum -= 1.0 / SIM_HZ
                _sim_tick()
        # 表现同步（每帧）
        _sync_view(delta)

func _sim_tick() -> void:
        # 玩家 0 = 本地输入
        match_sim.set_command(0, _local_command())
        # bot 思考（每 tick 出指令, 内部有决策节流）
        # bot AI 16Hz 节流 (与原版 bot 决策频率一致, 命令在思考间隙保持)
        var ai_now := Time.get_ticks_msec()
        if ai_now - _ai_last_ms >= 62:
                _ai_last_ms = ai_now
                for ai in bots:
                        var cmd: Dictionary = ai.think(DL.DT)
                        match_sim.set_command(ai.player.id, cmd)
        match_sim.step()

func _sync_view(delta: float) -> void:
        var me: DLPlayer = match_sim.players[0]
        if camera == null:
                return
        camera.position = me.eye()
        var kick_up: float = me.recoil.y * DLWeapons.RECOIL_SCALE + me.view_punch.y
        var kick_yaw: float = me.recoil.x * DLWeapons.RECOIL_SCALE + me.view_punch.x
        camera.rotation.y = deg_to_rad(me.yaw + kick_yaw) + PI
        camera.rotation.x = deg_to_rad(-me.pitch + kick_up)
        # ADS
        var wd := DLWeapons.get_weapon(me.gun)
        var target_fov := _source_vfov(90.0)
        if me.zoom_level > 0:
                target_fov = _source_vfov(float(wd.zoom_fov1)) if me.zoom_level == 1 else _source_vfov(float(wd.zoom_fov2))
        camera.fov = lerpf(camera.fov, target_fov, delta * 12.0)
        # 走路镜头晃动
        if me.grounded and me.velocity.length() > 1.0:
                bob_time += delta * me.velocity.length() * 1.4
                camera.position.y += sin(bob_time * 2.0) * 0.012
        # 尸体/身体同步
        (world as Node3D).update_body(me)
        for p in match_sim.players:
                (world as Node3D).update_body(p)
        # HUD
        hud.hp_label.text = "♥ %d" % me.health
        hud.armor_label.text = "🛡 %d" % me.armor
        if DLWeapons.is_firearm(me.gun):
                hud.ammo_label.text = "%d / %d" % [me.ammo[me.gun], me.reserve[me.gun]]
        else:
                hud.ammo_label.text = DLWeapons.get_weapon(me.gun).name
        hud.money_label.text = "$%d" % me.money
        var phase_text := ""
        match match_sim.phase:
                DL.RoundPhase.PREPARE: phase_text = "准备阶段 %.0fs" % maxf(0, match_sim.phase_left)
                DL.RoundPhase.LIVE: phase_text = "第 %d 回合  CT %d : %d T" % [match_sim.round_num, match_sim.score[0], match_sim.score[1]]
                DL.RoundPhase.RESULT: phase_text = "回合结束"
                DL.RoundPhase.MATCH_OVER: phase_text = "比赛结束!"
        if match_sim.mode == DLMatch.Mode.WAVE:
                phase_text = "第 %d 波  存活: %d" % [match_sim.wave, match_sim.alive_count(0)]
        elif match_sim.mode == DLMatch.Mode.TDM:
                phase_text = "CT %d : %d T  ·  我的K/D: %d/%d" % [match_sim.score[0], match_sim.score[1], me.kills, me.deaths]
        hud.mode_label.text = phase_text
        # 准星扩散
        var inacc := DLWeapons.inaccuracy(me, me.zoom_level > 0) if DLWeapons.is_firearm(me.gun) else 0.004
        hud.set_crosshair_gap(6.0 + inacc * 900.0)
        # 闪光
        hud.set_flash(me.flash_left / maxf(0.3, me.flash_peak) if me.flash_peak > 0 else 0.0)
        # 计分板内容
        if hud.scoreboard_visible:
                _update_scoreboard()

func _unhandled_input(event: InputEvent) -> void:
        if not playing:
                return
        if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
                var me: DLPlayer = match_sim.players[0]
                me.yaw = wrapf(me.yaw - event.relative.x * mouse_sensitivity * rad_to_deg(1.0), 0.0, 360.0)
                me.pitch = clampf(me.pitch - event.relative.y * mouse_sensitivity * rad_to_deg(1.0), -89.0, 89.0)
        elif event is InputEventKey and event.pressed:
                match event.physical_keycode:
                        KEY_TAB:
                                hud.toggle_scoreboard()
                        KEY_B:
                                if match_sim.phase == DL.RoundPhase.PREPARE:
                                        hud.toggle_buy()
                        KEY_ESCAPE:
                                Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED

func _local_command() -> Dictionary:
        var me: DLPlayer = match_sim.players[0]
        var cmd := {"x": 0.0, "z": 0.0, "yaw": me.yaw, "pitch": me.pitch, "buttons": 0,
                "weapon": me.gun, "buy": 0}
        var fwd := Input.is_action_pressed("ui_up") or Input.is_physical_key_pressed(KEY_W)
        var back := Input.is_physical_key_pressed(KEY_S)
        var left := Input.is_physical_key_pressed(KEY_A)
        var right := Input.is_physical_key_pressed(KEY_D)
        cmd.x = (1.0 if right else 0.0) - (1.0 if left else 0.0)
        cmd.z = (1.0 if fwd else 0.0) - (1.0 if back else 0.0)
        var b := 0
        if Input.is_action_pressed("fire"):
                b |= DL.B_FIRE
        if Input.is_action_pressed("alt_fire"):
                b |= DL.B_SCOPE
        if Input.is_action_pressed("jump"):
                b |= DL.B_JUMP
        if Input.is_action_pressed("walk"):
                b |= DL.B_WALK
        if Input.is_action_pressed("reload"):
                b |= DL.B_RELOAD
        if Input.is_action_pressed("use"):
                b |= DL.B_USE
        if Input.is_action_pressed("drop_weapon"):
                b |= DL.B_DROP_WEAPON
        cmd.buttons = b
        # 切枪
        if Input.is_action_just_pressed("weapon_primary") and me.primary() >= 0:
                cmd.weapon = me.primary()
        elif Input.is_action_just_pressed("weapon_secondary") and me.secondary() >= 0:
                cmd.weapon = me.secondary()
        elif Input.is_action_just_pressed("weapon_knife"):
                cmd.weapon = DL.KNIFE
        elif Input.is_action_just_pressed("grenade_cycle"):
                var next: int = me.next_grenade(me.gun)
                if next >= 0:
                        cmd.weapon = next
        # 下包
        if Input.is_physical_key_pressed(KEY_G) and me.bomb_equipped:
                match_sim.try_plant(me)  # 直接尝试(简化丢包→原地放置)
        # 购买快捷键 B 面板逻辑在 hud
        return cmd

# ---------------- 事件 → 表现 ----------------
func _on_kill(killer: int, victim: int, weapon: int, headshot: bool, penetrated: bool) -> void:
        var kn := "未知"
        if killer < match_sim.players.size():
                kn = DLWeapons.get_weapon(weapon).name
                var kname := "CT%d" % killer if match_sim.players[killer].team == 0 else "T%d" % killer
                var vname := "CT%d" % victim if match_sim.players[victim].team == 0 else "T%d" % victim
                var col := Color(0.6, 0.8, 1) if match_sim.players[killer].team == 0 else Color(1, 0.75, 0.5)
                hud.add_kill_entry("%s %s%s %s" % [kname, "[穿透]" if penetrated else "", "[爆头]" if headshot else "", vname], col)
        else:
                vname2(kn, victim, weapon)

func vname2(kn: String, victim: int, weapon: int) -> void:
        var vname := "CT%d" % victim if match_sim.players[victim].team == 0 else "T%d" % victim
        hud.add_kill_entry("%s 被 %s 击杀" % [vname, kn], Color(0.8, 0.8, 0.8))

func _on_impact(pos: Vector3, material: int, kind: int) -> void:
        Fx.impact(pos, Vector3.UP, material)

func _on_sound(name: String, pos: Vector3, player_id: int) -> void:
        Bank.play_event(name, pos, world)

func _on_grenade(action: String, g: Dictionary) -> void:
        match action:
                "explosion":
                        Fx.explosion(g.position)
                "flash":
                        pass
                "smoke_start":
                        Fx.smoke_cloud(g.position, 16.5)
                "fire_start":
                        Fx.fire_zone(g.position, 7.0)
                "throw":
                        var mi := Fx.grenade_mesh(int(g.gun))
                        world.add_child(mi)
                        mi.global_position = g.position
                        var tw := create_tween()
                        tw.tween_property(mi, "global_position", g.position + g.velocity * 1.5 + Vector3(0, -9.8 * 1.1, 0), 1.5)
                        tw.tween_callback(mi.queue_free)

func _on_bomb(action: String, site: int, pos: Vector3, player_id: int) -> void:
        match action:
                "planted":
                        hud.show_banner("炸弹已安放 (A点)" if site == 1 else "炸弹已安放 (B点)", Color(1, 0.6, 0.3))
                        Bank.play_ui("wave_start")
                "defused":
                        hud.show_banner("炸弹已拆除!", Color(0.5, 0.8, 1))
                "exploded":
                        Fx.explosion(pos, true)
                        hud.show_banner("炸弹爆炸!", Color(1, 0.4, 0.3))

func _on_round(phase: int, winner: int, reason: String) -> void:
        match phase:
                DL.RoundPhase.LIVE:
                        hud.show_banner("行动开始!", Color(0.9, 0.9, 0.7))
                        Bank.play_ui("round_start")
                DL.RoundPhase.RESULT:
                        if winner == match_sim.players[0].team:
                                hud.show_banner("回合胜利", Color(0.5, 1, 0.5))
                                Bank.play_ui("victory")
                        else:
                                hud.show_banner("回合失败", Color(1, 0.5, 0.5))
                                Bank.play_ui("defeat")
                DL.RoundPhase.MATCH_OVER:
                        if winner == match_sim.players[0].team:
                                hud.show_banner("比赛胜利!", Color(0.5, 1, 0.5))
                        else:
                                hud.show_banner("比赛失败", Color(1, 0.5, 0.5))
                        Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
                DL.RoundPhase.PREPARE:
                        if reason.begins_with("wave"):
                                hud.show_banner("第 %d 波 来袭!" % match_sim.wave, Color(1, 0.6, 0.3))

func _on_hit_feedback(attacker: int, victim: int, region: int, damage: int, killed: bool) -> void:
        if attacker == 0 and victim != 0:
                hud.show_hitmarker(killed, region == DL.HitRegion.HEAD)
                Bank.play_ui("hitmarker_head" if region == DL.HitRegion.HEAD else "hitmarker")
        if victim == 0:
                Bank.play_ui("damage_taken")

func _update_scoreboard() -> void:
        var lines := ""
        for p in match_sim.players:
                var q: DLPlayer = p
                var name := ("你" if q.id == 0 else ("BOT" if q.bot else "玩家")) + "·" + ("CT" if q.team == 0 else "T")
                lines += "%-12s  K:%-4d D:%-4d  $%d\n" % [name, q.kills, q.deaths, q.money]
        var lbl := hud.scoreboard.get_node_or_null("content")
        if lbl == null:
                lbl = Label.new()
                lbl.name = "content"
                lbl.add_theme_font_size_override("font_size", 17)
                hud.scoreboard.add_child(lbl)
        lbl.text = lines

static func _source_vfov(source_fov: float) -> float:
        ## 原版 Game.SourceVerticalFov: 2*atan(tan(fov/2)*0.75), 90 → 73.74
        return 2.0 * atan(tan(deg_to_rad(source_fov) * 0.5) * 0.75) * 57.29578
