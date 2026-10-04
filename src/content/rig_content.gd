class_name DLRigContent extends RefCounted
## 原版骨架运行时系统: rig_scenes/*.scn 实例化 + rig_materials 材质 + 动画查询

const CONTENT := "res://assets/content"
var materials: Dictionary = {}       # 材质名 → Material
var content: DLSourceContent
var _scene_cache: Dictionary = {}

func _init(src_content: DLSourceContent) -> void:
	content = src_content
	var rm: Dictionary = JSON.parse_string(_read_text(CONTENT + "/rig_materials.json"))
	if rm and rm.has("materials"):
		for m in rm.materials:
			materials[m.name] = m

func _read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f else "{}"

func instantiate(rig_name: String) -> Node3D:
	if _scene_cache.has(rig_name):
		var packed: PackedScene = _scene_cache[rig_name]
		return packed.instantiate() if packed else null
	var path := CONTENT + "/rig_scenes/" + rig_name + ".scn"
	var packed: PackedScene = load(path) if ResourceLoader.exists(path) else null
	_scene_cache[rig_name] = packed
	if packed == null:
		push_warning("骨架缺失: " + rig_name)
		return null
	var node := packed.instantiate()
	# 分配材质 (bake 时材质名存在 meta)
	var skel := node.find_child("Skeleton3D", true, false)
	if skel:
		for c in skel.get_children():
			if c is MeshInstance3D and c.mesh and c.mesh.get_surface_count() > 0:
				var mat_name: String = c.get_meta("material", "")
				var mat := _material_for(mat_name)
				if mat:
					c.set_surface_override_material(0, mat)
	return node

func _material_for(mat_name: String) -> Material:
	var rec: Dictionary = materials.get(mat_name, {})
	if rec.is_empty():
		return null
	var mat := StandardMaterial3D.new()
	if rec.is_empty():
		mat.albedo_color = Color(0.7, 0.7, 0.7)
		return mat
	var base := content.tex(rec.get("base", ""))
	if base:
		mat.albedo_texture = base
	var col: Array = rec.get("color", [1, 1, 1, 1])
	mat.albedo_color = Color(col[0], col[1], col[2], col[3])
	if rec.get("cutout", false):
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.alpha_scissor_threshold = 0.35
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var normal := content.tex(rec.get("normal", ""))
	if normal:
		mat.normal_enabled = true
		mat.normal_texture = normal
	mat.roughness = 0.87
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return mat

func has_clip(rig_name: String, clip: String) -> bool:
	var path := CONTENT + "/rig_scenes/" + rig_name + ".scn"
	if not ResourceLoader.exists(path):
		return false
	if not _scene_cache.has(rig_name):
		_scene_cache[rig_name] = load(path)
	var packed: PackedScene = _scene_cache[rig_name]
	if packed == null:
		return false
	var inst := packed.instantiate()
	var ap: AnimationPlayer = inst.find_child("AnimationPlayer", true, false)
	var has := ap != null and ap.has_animation(clip)
	inst.free()
	return has

func clip_names(rig_name: String) -> PackedStringArray:
	var out := PackedStringArray()
	var path := CONTENT + "/rig_scenes/" + rig_name + ".scn"
	if not ResourceLoader.exists(path):
		return out
	if not _scene_cache.has(rig_name):
		_scene_cache[rig_name] = load(path)
	var packed: PackedScene = _scene_cache[rig_name]
	if packed == null:
		return out
	var inst := packed.instantiate()
	var ap: AnimationPlayer = inst.find_child("AnimationPlayer", true, false)
	if ap:
		out = ap.get_animation_list()
	inst.free()
	return out

## rig_metadata.json 附件 (muzzle_flash / shell_eject 等) → {name: {bone, position, rotation}}
func attachments(rig_name: String) -> Dictionary:
	if _attach_cache.has(rig_name):
		return _attach_cache[rig_name]
	var out := {}
	var rm: Dictionary = JSON.parse_string(_read_text(CONTENT + "/rig_metadata.json"))
	if rm and rm.has("models"):
		for m in rm.models:
			if m.model == rig_name and m.has("attachments"):
				for a in m.attachments:
					out[a.name] = a
	_attach_cache[rig_name] = out
	return out

var _attach_cache: Dictionary = {}
