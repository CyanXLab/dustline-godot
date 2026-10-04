extends SceneTree
## 核心模拟冒烟测试: 跑 30 秒游戏时间, 验证移动/开火/AI/回合流转

func _init() -> void:
	var errors := 0
	var m := DLMatch.new(DLMatch.Mode.DEFUSAL, 8)
	var bots := []
	var bbs := {}
	for p in m.players:
		if p.bot:
			if not bbs.has(p.team):
				bbs[p.team] = {}
			bots.append(DLBotAI.new(p, m, bbs[p.team], 0.6))
	var kills := 0
	m.event_kill.connect(func(k, v, w, hs, pen): kills += 1)
	var shots := 0
	var moved := false
	var last_pos: Vector3 = m.players[0].position
	for t in 64 * 30:
		# bot 指令
		for ai in bots:
			m.set_command(ai.player.id, ai.think(DL.DT))
		# 模拟玩家0前进开火
		var cmd := {"x": 0.0, "z": 1.0, "yaw": 0.0, "pitch": 0.0, "buttons": DL.B_FIRE,
			"weapon": m.players[0].gun, "buy": 0}
		m.set_command(0, cmd)
		m.step()
		if m.players[0].position.distance_squared_to(last_pos) > 0.001:
			moved = true
		last_pos = m.players[0].position
		if kills >= 0 and t == 64 * 20:
			print("20s: kills=%d phase=%d round=%d score=%s" % [kills, m.phase, m.round_num, str(m.score)])
	print("=== 结果 ===")
	print("移动: ", moved)
	print("击杀数: ", kills)
	print("回合: ", m.round_num, " 比分: ", m.score)
	print("玩家0: hp=", m.players[0].health, " pos=", m.players[0].position, " kills=", m.players[0].kills, " money=", m.players[0].money)
	# 武器数据校验
	print("武器数: ", DLWeapons.count(), " AK价格: ", DLWeapons.get_weapon(0).price)
	# TDM 冒烟
	var tdm := DLMatch.new(DLMatch.Mode.TDM, 4)
	for t in 64 * 15:
		tdm.step()
	print("TDM 15s: score=", tdm.score, " over=", tdm.match_over)
	# 波次
	var wave_m := DLMatch.new(DLMatch.Mode.WAVE, 3)
	for t in 64 * 15:
		wave_m.step()
	print("WAVE 15s: wave=", wave_m.wave)
	print("SMOKE_TEST_PASS")
	quit(0)
