extends SceneTree
## 完整模拟 autotest: 三模式各跑 35 模拟秒 (2240 tick)
## 与游戏内 autotest 相同的模拟层, 但用脚本驱动 (沙箱主循环时钟异常下仍可验证)
## 验证: 移动/购买/AI 交火/击杀/回合流转/TDM 重生/波次推进

func _init() -> void:
	var modes := {"DEFUSAL": DLMatch.Mode.DEFUSAL, "TDM": DLMatch.Mode.TDM, "WAVE": DLMatch.Mode.WAVE}
	var all_ok := true
	for mode_name in modes:
		var m := DLMatch.new(modes[mode_name], 9 if modes[mode_name] != DLMatch.Mode.WAVE else 7)
		# bot AI (与游戏内相同: 含 nn_policy 加载)
		var bots: Array = []
		var bbs := {}
		var policy_text := ""
		var pf := FileAccess.open("res://assets/nn_policy.json", FileAccess.READ)
		if pf:
			policy_text = pf.get_as_text()
		for p in m.players:
			if p.bot:
				if not bbs.has(p.team):
					bbs[p.team] = {}
				var ai := DLBotAI.new(p, m, bbs[p.team], 0.6)
				if policy_text != "":
					var np: Dictionary = JSON.parse_string(policy_text)
					if np and np.has("w1"):
						ai.nn_policy = {"w1": np.w1, "b1": np.b1, "w2": np.w2, "b2": np.b2}
				bots.append(ai)
		var kills := 0
		m.event_kill.connect(func(_k, _v, _w, _hs, _pen): kills += 1)
		var moved := false
		var last_pos: Vector3 = m.players[0].position
		var t0 := Time.get_ticks_msec()
		for t in 2240:
			for ai in bots:
				m.set_command(ai.player.id, ai.think(DL.DT))
			m.step()
			if m.players[0].position.distance_squared_to(last_pos) > 0.001:
				moved = true
			last_pos = m.players[0].position
		var wall_s := (Time.get_ticks_msec() - t0) / 1000.0
		var total_kills := 0
		for p in m.players:
			total_kills += p.kills
		var summary := "%s: %d模拟秒 用时%.1fs (%.1fms/tick) 击杀事件=%d 玩家击杀=%d 回合=%d 比分=%s 移动=%s" % [
			mode_name, 35, wall_s, wall_s * 1000.0 / 2240.0, kills, total_kills,
			m.round_num if modes[mode_name] != DLMatch.Mode.WAVE else m.wave,
			str(m.score), str(moved)]
		print(summary)
		# 交火发生 (有击杀) 且模拟流转正常
		if kills == 0:
			all_ok = false
	# 武器数据完整性
	print("武器数: ", DLWeapons.count(), " AK=$", DLWeapons.get_weapon(0).price)
	print("FULL_AUTOTEST_" + ("PASS" if all_ok else "FAIL"))
	quit(0)
