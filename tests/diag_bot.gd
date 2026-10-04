extends SceneTree
## bot 行为诊断

func _init() -> void:
	var m := DLMatch.new(DLMatch.Mode.TDM, 6)
	var bots := []
	var bbs := {}
	for p in m.players:
		if p.bot:
			if not bbs.has(p.team):
				bbs[p.team] = {}
			bots.append(DLBotAI.new(p, m, bbs[p.team], 0.7))
	# TDM 无回合阶段, 直接 LIVE
	for t in 64 * 5:
		for ai in bots:
			m.set_command(ai.player.id, ai.think(DL.DT))
		m.step()
	print("=== 5s 后 bot 状态 ===")
	for p in m.players:
		if p.bot:
			print("bot%d team%d hp%d pos=(%.1f, %.1f, %.1f) vel=%.1f alive=%s" % [p.id, p.team, p.health, p.position.x, p.position.y, p.position.z, p.velocity.length(), str(p.alive())])
	# 寻路检查
	var path1: PackedVector3Array = m.map.path(Vector3(-2.4, 0, -40.8), Vector3(0, 0, 28.8))
	print("T出生→CT出生 路径点数: ", path1.size())
	var path2: PackedVector3Array = m.map.path(Vector3(25.2, 0, 27.6), Vector3(-30, 0, 27.6))
	print("A点→B点 路径点数: ", path2.size())
	# 敌我视线检查
	var ct: DLPlayer = null
	var t2: DLPlayer = null
	for p in m.players:
		if p.bot and p.team == 0 and ct == null: ct = p
		if p.bot and p.team == 1 and t2 == null: t2 = p
	if ct != null and t2 != null:
		print("CT eye=", ct.eye(), " T eye=", t2.eye())
		print("互相可见: ", m.map.visible(ct.eye(), t2.eye()))
	# 继续跑 25s 看交战
	var kills := 0
	m.event_kill.connect(func(k, v, w, hs, pen): kills += 1)
	for t in 64 * 25:
		for ai in bots:
			m.set_command(ai.player.id, ai.think(DL.DT))
		m.step()
	print("=== 30s 总计 === kills=", kills)
	for p in m.players:
		if p.bot:
			print("bot%d hp=%d kills=%d pos=(%.1f,%.1f,%.1f)" % [p.id, p.health, p.kills, p.position.x, p.position.y, p.position.z])
	quit(0)
