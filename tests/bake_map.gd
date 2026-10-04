extends SceneTree
## 离线烘焙: map_bake.gvb (Variant 二进制) → 原生 ArrayMesh .res (压缩二进制)
## 运行: godot --headless --path . --script res://tests/bake_map.gd

const GVB := "res://assets/content/map_bake.gvb"
const MANIFEST := "res://assets/content/map_bake.json"
const OUT_DIR := "res://assets/content/map_meshes"

func _init() -> void:
	var t0 := Time.get_ticks_msec()
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var f := FileAccess.open(GVB, FileAccess.READ)
	if f == null:
		push_error("缺少 " + GVB)
		quit(1)
		return
	var b := f.get_buffer(f.get_length())
	f.close()
	assert(b.slice(0, 4).get_string_from_ascii() == "GVV1")
	var n := b.decode_u32(4)
	var blobs_start := b.decode_s64(8)
	var off := 16
	var sections := {}
	for i in n:
		var nl := b.decode_u8(off)
		off += 1
		var nm := b.slice(off, off + nl).get_string_from_utf8()
		off += nl
		var so := b.decode_u64(off)
		off += 8
		var ss := b.decode_u64(off)
		off += 8
		sections[nm] = bytes_to_var(b.slice(blobs_start + so, blobs_start + so + ss))
	var mf: Dictionary = JSON.parse_string(FileAccess.open(MANIFEST, FileAccess.READ).get_as_text())
	var mesh_list: Array = mf.meshes
	var saved := 0
	var failed := 0
	for mi in range(mesh_list.size()):
		var m: Dictionary = mesh_list[mi]
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = sections[m.mesh + "_pos"]
		arrays[Mesh.ARRAY_NORMAL] = sections[m.mesh + "_nrm"]
		arrays[Mesh.ARRAY_TEX_UV] = sections[m.mesh + "_uv"]
		arrays[Mesh.ARRAY_COLOR] = sections[m.mesh + "_col"]
		if sections.has(m.mesh + "_uv2"):
			arrays[Mesh.ARRAY_TEX_UV2] = sections[m.mesh + "_uv2"]
		arrays[Mesh.ARRAY_INDEX] = sections[m.mesh + "_idx"]
		var am := ArrayMesh.new()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var aabb := AABB(Vector3(m.aabb_min[0], m.aabb_min[1], m.aabb_min[2]),
			Vector3(m.aabb_max[0], m.aabb_max[1], m.aabb_max[2]) - Vector3(m.aabb_min[0], m.aabb_min[1], m.aabb_min[2]))
		am.custom_aabb = aabb
		var out_path: String = OUT_DIR + "/" + m.mesh + ".res"
		var serr: int = ResourceSaver.save(am, out_path, ResourceSaver.FLAG_COMPRESS)
		if serr != OK:
			push_error("保存失败 " + out_path + " err=%d" % serr)
			failed += 1
		else:
			saved += 1
	print("BAKE: 保存 %d 失败 %d 用时 %.1fs" % [saved, failed, (Time.get_ticks_msec() - t0) / 1000.0])
	quit(0 if failed == 0 else 1)
