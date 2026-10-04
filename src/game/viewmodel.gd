class_name DLViewModel extends Node3D
## WeaponView 简化移植: 真实武器视图模型 + 动画状态机 (draw/fire/reload/idle)
## 摆位数据: 原版默认 ViewmodelX=2.5 Y=0 Z=-1.5 (×0.0254m), FOV 68→54.4°

var rig_content: DLRigContent
var player: DLPlayer
var pivot: Node3D
var current_gun := -1
var current_rig: Node3D
var current_anim: AnimationPlayer
var fire_seq := 0
var last_shots := -1
var was_reloading := false
var time := 0.0

const DEF_PIVOT := Vector3(2.5, 0.0, -1.5)   # (X, Y, Z) 原版默认

func _init(rc: DLRigContent, p: DLPlayer) -> void:
	rig_content = rc
	player = p
	pivot = Node3D.new()
	pivot.name = "ViewmodelPivot"
	# Unity 相机 +z 朝前; Godot 相机 -z → 绕 Y 转 180°
	pivot.rotation.y = PI
	add_child(pivot)
	pivot.position = Vector3(DEF_PIVOT.x, DEF_PIVOT.z, DEF_PIVOT.y) * 0.0254
	_switch_to(p.gun)

func _weapon_rig(gun: int) -> String:
	var wd := DLWeapons.get_weapon(gun)
	var key: String = wd.get("key", "knife_bayonet")
	if int(wd.get("kind", 0)) == DL.WeaponKind.GRENADE:
		key = wd.get("viewmodel", key)
	return key + "_view"

func _switch_to(gun: int) -> void:
	current_gun = gun
	for c in pivot.get_children():
		c.queue_free()
	current_rig = null
	current_anim = null
	var rig_name := _weapon_rig(gun)
	if rig_content == null:
		return
	var rig := rig_content.instantiate(rig_name)
	if rig == null:
		return
	current_rig = rig
	pivot.add_child(rig)
	current_anim = rig.find_child("AnimationPlayer", true, false)
	last_shots = player.shots
	_play("draw", "idle")

func find_clip(names: Array) -> String:
	if current_anim == null:
		return ""
	for n in names:
		if n == null or n == "":
			continue
		var list := current_anim.get_animation_list()
		var lower := String(n).to_lower()
		for a in list:
			if String(a).to_lower() == lower:
				return a
		for a in list:
			if String(a).to_lower().contains(lower):
				return a
	return ""

func _play(anim_name: String, fallback := "") -> void:
	if current_anim == null:
		return
	var clip := find_clip([anim_name])
	if clip == "":
		clip = find_clip([fallback])
	if clip != "":
		current_anim.play(clip, 0.1)

func _process(delta: float) -> void:
	time += delta
	if player == null or not is_instance_valid(player):
		return
	# 换枪
	if player.gun != current_gun:
		_switch_to(player.gun)
		return
	if current_anim == null:
		return
	# 开火检测 (shots 计数器)
	if player.shots != last_shots:
		last_shots = player.shots
		fire_seq = (fire_seq + 1) % 3
		_play("fire" + str(fire_seq + 1), "fire1")
		return
	# 换弹检测
	var reloading := player.reload_left > 0.0
	if reloading and not was_reloading:
		_play("reload", "idle")
	was_reloading = reloading
	if not reloading and current_anim.current_animation != "" \
			and current_anim.current_animation.to_lower().contains("reload") \
			and not current_anim.is_playing():
		_play("idle")
	# 开镜隐藏 (原版 hidescoped)
	var wd := DLWeapons.get_weapon(player.gun)
	if bool(wd.get("hidescoped", false)) and player.zoom_level > 0:
		visible = false
	else:
		visible = true
	# 行走摆动 (原版: sin(time*10)*speed*0.0015)
	var speed := Vector2(player.velocity.x, player.velocity.z).length()
	pivot.position.y = Vector3(DEF_PIVOT.x, DEF_PIVOT.z, DEF_PIVOT.y).y * 0.0254 \
		+ sin(time * 10.0) * minf(speed, 3.0) * 0.0015
