extends SceneTree
## 完整场景冒烟测试: 加载 main.tscn → 启动对局 → 跑 300 帧

var frames := 0
var main: Node

func _init() -> void:
	var ps: PackedScene = load("res://src/game/main.tscn")
	main = ps.instantiate()
	root.add_child(main)
	# 直接启动 TDM 对局
	main._start(DLMatch.Mode.TDM)
	process_frame.connect(_tick)

func _tick() -> void:
	frames += 1
	if frames == 120:
		var m = main.match_sim
		print("120帧: tick=", m.tick, " 玩家数=", m.players.size(), " phase=", m.phase)
		# 模拟 2 秒 64Hz 模拟
		for i in 128:
			for ai in main.bots:
				m.set_command(ai.player.id, ai.think(DL.DT))
			m.step()
		print("模拟2s后: kills 统计中...")
		var mk := 0
		for p in m.players:
			mk += p.kills
		print("总击杀: ", mk)
	if frames >= 180:
		print("SCENE_TEST_PASS")
		quit(0)
