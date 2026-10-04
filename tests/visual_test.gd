extends SceneTree
func _init() -> void:
	var t0 := Time.get_ticks_msec()
	var wb: Node3D = load("res://src/game/world_builder.gd").new()
	var map := DLMap.new()
	root.add_child(wb)
	wb.build(map)
	var meshes := 0
	var mats := {}
	for c in wb.get_children():
		if c is MeshInstance3D:
			meshes += 1
			if c.material_override != null:
				mats[c.material_override.get_class()] = mats.get(c.material_override.get_class(), 0) + 1
	print("视觉构建: %d 网格实例 材质: %s 用时 %.1fs" % [meshes, mats, (Time.get_ticks_msec() - t0) / 1000.0])
	print("lightmap=", wb.content.lightmap != null, " 天空dome变换检查:")
	for c in wb.get_children():
		if c is Node3D and c.name == "OriginalDust2":
			for gc in c.get_children():
				if gc is MeshInstance3D and gc.scale.x > 1.0:
					print("  dome scale=", gc.scale, " pos=", gc.position)
	quit()
