extends SceneTree
## 纯引擎帧率探针: 零节点零资产, 统计每5秒帧数

var frames := 0
var acc := 0.0

func _process(delta: float) -> bool:
	frames += 1
	acc += delta
	if acc >= 5.0:
		print("FRAMES_IN_5S=%d last_delta=%.3f" % [frames, delta])
		acc = 0.0
		frames = 0
	return false
