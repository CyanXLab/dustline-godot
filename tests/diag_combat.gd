extends SceneTree
func _init() -> void:
	var m := DLMatch.new(DLMatch.Mode.DEFUSAL, 8)
	var bots := []
	var bbs := {}
	for p in m.players:
		if p.bot:
			if not bbs.has(p.team):
				bbs[p.team] = {}
			bots.append(DLBotAI.new(p, m, bbs[p.team], 0.6))
	m.event_kill.connect(func(k, v, w, hs, pen): print("KILL: killer=%d victim=%d w=%d hs=%s" % [k, v, w, hs]))
	m.event_impact.connect(func(pos, mat, flesh): pass)
	var cmds := {}
	for ai in bots:
		cmds[ai.player.id] = ai
	for t in 64 * 40:
		for id in cmds:
			m.set_command(id, cmds[id].think(DL.DT))
		m.step()
		if t % (64 * 10) == 0:
			var alive := []
			for p in m.players:
				if p.alive():
					alive.append("p%d(t%d hp%d %s)" % [p.id, p.team, p.health, p.position.snapped(Vector3(1, 1, 1))])
			print("t=%ds alive: %s" % [t / 64, ", ".join(alive)])
	quit()
