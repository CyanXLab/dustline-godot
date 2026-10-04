extends SceneTree
## 纹理分类: 输出每个 ctex 的 {format, w, h, mipmaps, bytes} → /tmp/tex_class.json
## 用于决定哪些 DXT5 可无损观感转 DXT1 (BC3→BC1)

func _init() -> void:
	var dir := DirAccess.open("res://assets/textures")
	if dir == null:
		print("ERR: no textures dir")
		quit(1)
		return
	var out := {}
	var names := dir.get_files()
	names.sort()
	for f in names:
		if not f.ends_with(".ctex"):
			continue
		var path := "res://assets/textures/" + f
		var fa := FileAccess.open(path, FileAccess.READ)
		var bytes := fa.get_length() if fa else 0
		var t: Texture2D = load(path)
		if t == null:
			out[f] = {"err": "load_null", "bytes": bytes}
			continue
		var img: Image = t.get_image()
		if img == null:
			out[f] = {"err": "img_null", "bytes": bytes}
			continue
		out[f] = {
			"fmt": img.get_format(),
			"w": img.get_width(),
			"h": img.get_height(),
			"mips": img.has_mipmaps(),
			"bytes": bytes,
		}
	var fj := JSON.stringify(out)
	var of := FileAccess.open("/tmp/tex_class.json", FileAccess.WRITE)
	if of:
		of.store_string(fj)
		of.close()
	print("CLASSIFIED:", out.size())
	quit(0)
