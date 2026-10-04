extends SceneTree
## 离线烘焙骨架: rig_payload/*.gvb → rig_scenes/*.scn (Skeleton3D+蒙皮网格+动画)
## 运行: godot --headless --path . --script res://tests/bake_rigs.gd

const PAYLOAD := "res://assets/content/rig_payload"
const MANIFEST := "res://assets/content/rigs_bake.json"
const OUT_DIR := "res://assets/content/rig_scenes"

func _init() -> void:
	var t0 := Time.get_ticks_msec()
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var mf: Array = JSON.parse_string(FileAccess.open(MANIFEST, FileAccess.READ).get_as_text())
	var ok := 0
	var fail := 0
	for mi in range(mf.size()):
		var m: Dictionary = mf[mi]
		if _bake_one(m):
			ok += 1
		else:
			fail += 1
		if mi % 20 == 0:
			print("  %d/%d %.0fs" % [mi, mf.size(), (Time.get_ticks_msec() - t0) / 1000.0])
	print("RIG BAKE: 成功 %d 失败 %d 用时 %.0fs" % [ok, fail, (Time.get_ticks_msec() - t0) / 1000.0])
	quit(0 if fail == 0 else 1)

func _read_sections(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var b := f.get_buffer(f.get_length())
	f.close()
	if b.slice(0, 4).get_string_from_ascii() != "GVV1":
		return {}
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
	return sections

func _bake_one(m: Dictionary) -> bool:
	var secs := _read_sections(PAYLOAD + "/" + m.name + ".gvb")
	if secs.is_empty():
		push_error("载荷缺失 " + m.name)
		return false
	var root := Node3D.new()
	root.name = m.name
	var skel := Skeleton3D.new()
	skel.name = "Skeleton3D"
	root.add_child(skel)
	skel.owner = root
	# 骨骼
	var bones: Array = m.bones
	for i in range(bones.size()):
		var b: Dictionary = bones[i]
		var bname: String = String(b.name).replace(".", "_")
		var bi := skel.add_bone(bname)
		skel.set_bone_parent(bi, b.parent)
		var q := Quaternion(b.rot[0], b.rot[1], b.rot[2], b.rot[3])
		var rest := Transform3D(Basis(q), Vector3(b.pos[0], b.pos[1], b.pos[2]))
		skel.set_bone_rest(bi, rest)
		skel.set_bone_pose_position(bi, rest.origin)
		skel.set_bone_pose_rotation(bi, q)
	# 蒙皮部件
	for part: Dictionary in m.parts:
		var pid: String = part.pid
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = secs[pid + "_pos"]
		arrays[Mesh.ARRAY_NORMAL] = secs[pid + "_nrm"]
		arrays[Mesh.ARRAY_TEX_UV] = secs[pid + "_uv"]
		var bidx_f: PackedFloat32Array = secs[pid + "_bidx"]
		var bw_f: PackedFloat32Array = secs[pid + "_bw"]
		var nb := bidx_f.size()
		var bones_arr := PackedInt32Array()
		bones_arr.resize(nb)
		for i in nb:
			bones_arr[i] = int(bidx_f[i])
		arrays[Mesh.ARRAY_BONES] = bones_arr
		arrays[Mesh.ARRAY_WEIGHTS] = bw_f
		arrays[Mesh.ARRAY_INDEX] = secs[pid + "_idx"]
		var am := ArrayMesh.new()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		am.surface_set_name(0, part.part)
		var mi := MeshInstance3D.new()
		mi.name = part.part if part.part != "" else pid
		mi.mesh = am
		mi.set_meta("material", part.material)
		# 材质名存 meta, 运行时按 rig_materials 构建并分配
		skel.add_child(mi)
		mi.owner = root
	# 动画
	var lib := AnimationLibrary.new()
	for clip: Dictionary in m.clips:
		var cid: String = clip.cid
		var pos_data: PackedVector3Array = secs[cid + "_pos"]
		var quat_data: PackedFloat32Array = secs[cid + "_quat"]
		var frames: int = clip.frames
		var nb2: int = bones.size()
		var dur: float = maxf(1.0, frames - 1) / maxf(0.001, clip.fps)
		var anim := Animation.new()
		anim.length = dur
		for b_i in range(nb2):
			var bone_name: String = String(bones[b_i].name).replace(".", "_")
			var pt := anim.add_track(Animation.TYPE_POSITION_3D)
			anim.track_set_path(pt, "Skeleton3D:" + bone_name)
			var rt := anim.add_track(Animation.TYPE_ROTATION_3D)
			anim.track_set_path(rt, "Skeleton3D:" + bone_name)
			var fpos := b_i * frames
			for fr in range(frames):
				var tt := float(fr) / maxf(1.0, frames - 1) * dur
				anim.track_insert_key(pt, tt, pos_data[fpos + fr])
				var q := Quaternion(quat_data[(fpos + fr) * 4], quat_data[(fpos + fr) * 4 + 1],
					quat_data[(fpos + fr) * 4 + 2], quat_data[(fpos + fr) * 4 + 3])
				anim.track_insert_key(rt, tt, q)
		if clip.loop:
			anim.loop_mode = Animation.LOOP_LINEAR
		var cname: String = clip.name.trim_prefix("@")
		lib.add_animation(cname, anim)
	var ap := AnimationPlayer.new()
	ap.name = "AnimationPlayer"
	root.add_child(ap)
	ap.owner = root
	ap.add_animation_library("", lib)
	var scene := PackedScene.new()
	var packed := scene.pack(root)
	if packed != OK:
		push_error("打包失败 " + m.name)
		return false
	var serr: int = ResourceSaver.save(scene, OUT_DIR + "/" + m.name + ".scn", ResourceSaver.FLAG_COMPRESS)
	if serr != OK:
		push_error("保存失败 " + m.name + " err=%d" % serr)
		return false
	root.free()
	return true
