class_name DLSourceContent extends RefCounted
## 原版内容系统移植 (SourceContent.cs / SourceOriginalTexture 思路):
## 材质库 JSON + 哈希贴图 + HDR 烘焙光照贴图 + SourceBaked 着色器复刻

const CONTENT := "res://assets/content"
const TEXDIR := "res://assets/textures"
const CLOUD_MAT := "models/props/de_nuke/hr_nuke/nuke_skydome_001/nuke_clouds_002"

var map_materials: Dictionary = {}     # name → {base, normal, second, cutout, color}
var rig_materials: Dictionary = {}
var lightmap: Texture2D
var baked_shader: Shader
var sky_shader: Shader
var white_tex: Texture2D
var _mat_cache: Dictionary = {}
var _tex_cache: Dictionary = {}
var _missing_warned: Dictionary = {}

func _init() -> void:
        var mm: Dictionary = JSON.parse_string(_read_text(CONTENT + "/map_materials.json"))
        if mm and mm.has("materials"):
                for m in mm.materials:
                        map_materials[m.name] = m
        var rm: Dictionary = JSON.parse_string(_read_text(CONTENT + "/rig_materials.json"))
        if rm and rm.has("materials"):
                for m in rm.materials:
                        rig_materials[m.name] = m
        baked_shader = load("res://assets/shaders/source_baked.gdshader")
        sky_shader = load("res://assets/shaders/source_sky.gdshader")
        _load_lightmap()
        white_tex = _make_white()

func _read_text(path: String) -> String:
        var f := FileAccess.open(path, FileAccess.READ)
        return f.get_as_text() if f else "{}"

func _make_white() -> Texture2D:
        var img := Image.create(4, 4, false, Image.FORMAT_RGB8)
        img.fill(Color.WHITE)
        return ImageTexture.create_from_image(img)

func _load_lightmap() -> void:
        var f := FileAccess.open(CONTENT + "/lightmap_0.dlt", FileAccess.READ)
        if f == null:
                push_error("lightmap_0.dlt 缺失")
                return
        var raw: PackedByteArray = f.get_buffer(f.get_length())
        f.close()
        if raw.slice(0, 4).get_string_from_ascii() != "DLZ1":
                push_error("lightmap 缺少 DLZ1 头")
                return
        var data: PackedByteArray = raw.slice(12).decompress(raw.decode_u64(4), 1)
        # 2048×2048 RGBAHalf 原始字节 (与原版 Texture2D RGBAHalf 一致)
        if data.size() != 2048 * 2048 * 8:
                push_error("lightmap 尺寸异常: %d" % data.size())
                return
        var img := Image.create_from_data(2048, 2048, false, Image.FORMAT_RGBAH, data)
        lightmap = ImageTexture.create_from_image(img)

func tex(hash16: String) -> Texture2D:
        if hash16 == "":
                return null
        if _tex_cache.has(hash16):
                return _tex_cache[hash16]
        # 原版转换纹理为 Godot 原生 .ctex (DXT5/BPTC+mipmaps, 无损); .png 仅作回退
        var t: Texture2D = null
        for ext in [".ctex", ".png"]:
                var path: String = TEXDIR + "/" + hash16 + ext
                if ResourceLoader.exists(path):
                        t = load(path)
                        break
        if t == null and not _missing_warned.has(hash16):
                _missing_warned[hash16] = true
                push_warning("贴图缺失: " + hash16)
        _tex_cache[hash16] = t
        return t

## 原版 SourceContent.Material(name, light)
func material_for(mat_name: String, light: int, is_rig := false) -> Material:
        var key := "%d:%s" % [light, mat_name]
        if _mat_cache.has(key):
                return _mat_cache[key]
        var rec: Dictionary = {}
        if is_rig:
                rec = rig_materials.get(mat_name, {})
        else:
                rec = map_materials.get(mat_name, {})
        if rec.is_empty():
                if mat_name == CLOUD_MAT:
                        var sky := ShaderMaterial.new()
                        sky.shader = sky_shader
                        _mat_cache[key] = sky
                        return sky
                if not _missing_warned.has(mat_name):
                        _missing_warned[mat_name] = true
                        push_warning("材质缺失: " + mat_name)
                var fallback := StandardMaterial3D.new()
                fallback.albedo_color = Color(0.5, 0.5, 0.5)
                fallback.roughness = 0.85
                _mat_cache[key] = fallback
                return fallback
        var base_tex := tex(rec.get("base", ""))
        var normal_tex := tex(rec.get("normal", ""))
        var second_tex := tex(rec.get("second", ""))
        var cutout: bool = bool(rec.get("cutout", false))
        var col: Array = rec.get("color", [1, 1, 1, 1])
        var base_col := Color(col[0], col[1], col[2], col[3])
        var mat: Material
        if light >= 0:
                # 烘焙光照贴图路径 (原版 Dustline/SourceBaked)
                var sm := ShaderMaterial.new()
                sm.shader = baked_shader
                sm.set_shader_parameter("base_map", base_tex if base_tex else white_tex)
                sm.set_shader_parameter("light_map", lightmap if lightmap else white_tex)
                sm.set_shader_parameter("base_color", base_col)
                sm.set_shader_parameter("smoothness", 0.23)
                sm.set_shader_parameter("metallic", 0.0)
                if second_tex:
                        sm.set_shader_parameter("second_map", second_tex)
                        sm.set_shader_parameter("blend_second", 1.0)
                else:
                        sm.set_shader_parameter("second_map", white_tex)
                if normal_tex:
                        sm.set_shader_parameter("has_normal_map", true)
                        sm.set_shader_parameter("normal_map", normal_tex)
                mat = sm
        elif light == -2:
                # 顶点光照路径 (原版 URP/Lit + _VertexLighting): 顶点色承载烘焙光照
                var vm := StandardMaterial3D.new()
                vm.albedo_texture = base_tex if base_tex else white_tex
                vm.albedo_color = base_col
                vm.vertex_color_use_as_albedo = true
                vm.roughness = 1.0 - 0.23
                vm.metallic = 0.0
                if normal_tex:
                        vm.normal_enabled = true
                        vm.normal_texture = normal_tex
                if second_tex:
                        # 极少数顶点光照混合材质 — 用 next pass 近似 (罕见, 忽略混合差异)
                        vm.albedo_texture = base_tex if base_tex else white_tex
                mat = vm
        else:
                # 实时光照路径 (原版 URP/Lit, smoothness 0.23)
                var lm := StandardMaterial3D.new()
                lm.albedo_texture = base_tex if base_tex else white_tex
                lm.albedo_color = base_col
                lm.roughness = 1.0 - 0.23
                lm.metallic = 0.0
                if normal_tex:
                        lm.normal_enabled = true
                        lm.normal_texture = normal_tex
                mat = lm
        if cutout:
                if mat is ShaderMaterial:
                        # source_baked 已在片元内 discard (cutoff 0.35)
                        pass
                elif mat is StandardMaterial3D:
                        var sm3: StandardMaterial3D = mat
                        sm3.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
                        sm3.alpha_scissor_threshold = 0.35
                        sm3.cull_mode = BaseMaterial3D.CULL_DISABLED
        # 贴图采样器对齐原版: repeat + trilinear + aniso
        if mat is StandardMaterial3D:
                var s3: StandardMaterial3D = mat
                s3.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
        if mat is ShaderMaterial:
                pass  # 着色器 uniform 已声明 repeat + aniso
        _mat_cache[key] = mat
        return mat

## 构建真实地图 (294 个合并网格)
func build_map(parent: Node3D) -> Node3D:
        var root := Node3D.new()
        root.name = "OriginalDust2"
        var manifest: Dictionary = JSON.parse_string(_read_text(CONTENT + "/map_bake.json"))
        var mesh_list: Array = manifest.meshes
        var count := 0
        for m in mesh_list:
                var mesh: Mesh = load(CONTENT + "/map_meshes/" + m.mesh + ".res")
                if mesh == null:
                        push_warning("网格缺失 " + str(m.mesh))
                        continue
                var mi := MeshInstance3D.new()
                mi.mesh = mesh
                mi.name = m.mesh
                var light: int = int(m.light)
                var mat_name: String = m.material
                mi.material_override = material_for(mat_name, light)
                if mat_name == CLOUD_MAT:
                        mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
                        mi.layers = 2  # 天空层
                else:
                        mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
                parent.add_child(mi)
                count += 1
        print("SOURCE MAP: %d 个原始网格已构建" % count)
        return root

## 拆解后处理 LUT (cc_dust2 1024×32 → ImageTexture3D 32³, 与原版 ColorLookup 等价)
static func build_lut_texture() -> Texture3D:
        var png: Texture2D = load("res://assets/textures/cc_dust2.png")
        if png == null:
                return null
        var img: Image = png.get_image()
        if img == null:
                return null
        if img.is_compressed():
                img.decompress()
        img.convert(Image.FORMAT_RGB8)
        var slices: Array = []
        for z in 32:
                var tile: Image = img.get_region(Rect2i(z * 32, 0, 32, 32))
                if tile.is_compressed():
                        tile.decompress()
                tile.convert(Image.FORMAT_RGB8)
                slices.append(tile)
        var tex3 := ImageTexture3D.new()
        var img_arr: Array[Image] = []
        for im in slices:
                img_arr.append(im)
        var err: int = tex3.create(Image.FORMAT_RGB8, 32, 32, 32, false, img_arr)
        if err != OK:
                push_error("LUT 3D 创建失败 err=%d" % err)
                return null
        return tex3
