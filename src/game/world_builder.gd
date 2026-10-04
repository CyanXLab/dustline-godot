extends Node3D
## 世界构建器 (完整移植版): 原版 dust2 几何体 + 原版光照/雾/天空/后处理
## 光照参数 1:1 来自原版 LightingArt.cs / dust2.bin / sky_manifest.json

const SUN_ENERGY := 1.75
const SUN_COLOR := Color(0.99607843, 46.0 / 51.0, 0.77254903)
const SUN_ROT := Vector3(50.0, 47.0, 0.0)          # 原版 Quaternion.Euler(50,47,0)
const AMBIENT := Color(0.64, 0.68, 0.73)           # RenderSettings.ambientLight
const VIGNETTE := 0.09

var content: DLSourceContent
var rig_content: DLRigContent
var body_nodes: Dictionary = {}   # player_id → Node3D (bots)
var environment: Environment
var cam_attributes: CameraAttributesPractical
var sun: DirectionalLight3D

func build(map: DLMap) -> void:
        Fx.set_world(self)
        content = DLSourceContent.new()
        rig_content = DLRigContent.new(content)
        # 1) 真实地图 (294 个原始网格, 烘焙光照贴图)
        var map_root := content.build_map(self)
        # 1b) 3D 天空盒: 原版天球位于 1/16 天空空间, 等价变换 = ×16 缩放平移到世界
        #     sky→world: world = (sky - origin) * 16 → node.scale=16, node.position=-origin*16
        for child in map_root.get_children():
                if child is MeshInstance3D and child.material_override is ShaderMaterial:
                        var sm: ShaderMaterial = child.material_override
                        if sm.shader == content.sky_shader:
                                child.scale = Vector3.ONE * 16.0
                                child.position = -Vector3(-0.69004942, -209.0674, -12.1442988) * 16.0
                                print("SKY DOME: 变换至世界空间 (16x)")
        # 2) 原版太阳
        sun = DirectionalLight3D.new()
        sun.name = "OriginalSun"
        # Unity Euler(50,47,0) → Godot: pitch=-50 绕 Y=47 等价光照方向
        sun.rotation_degrees = Vector3(-SUN_ROT.x, SUN_ROT.y, 0.0)
        sun.light_color = SUN_COLOR
        sun.light_energy = SUN_ENERGY
        sun.shadow_enabled = true
        sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
        sun.shadow_blur = 1.0
        add_child(sun)
        # 3) 环境: 平直环境光 + 线性雾 + 自动曝光 + LUT 调色 (全部来自原版参数)
        var we := WorldEnvironment.new()
        environment = Environment.new()
        environment.background_mode = Environment.BG_COLOR
        environment.background_color = Color(0.75, 0.79, 0.85)
        environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
        environment.ambient_light_color = AMBIENT
        environment.ambient_light_energy = 1.0
        # 原版 fog: sky_manifest {start:-0.2286, end:228.6, maxDensity:0.6}
        environment.fog_enabled = true
        environment.fog_mode = Environment.FOG_MODE_DEPTH
        environment.fog_depth_begin = -0.2286
        environment.fog_depth_end = 228.6
        environment.fog_depth_curve = 1.0
        environment.fog_density = 0.6
        environment.fog_light_color = Color(0.75, 0.79, 0.85)
        environment.fog_sky_affect = 0.35
        # 自动曝光 (dust2.bin): min 0.5 max 1.25 rate 0.2 target 80%
        environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
        environment.tonemap_exposure = 1.0
        cam_attributes = CameraAttributesPractical.new()
        var cam_attr := cam_attributes
        cam_attr.auto_exposure_enabled = true
        cam_attr.auto_exposure_scale = 0.8
        cam_attr.auto_exposure_min_sensitivity = 66.0
        cam_attr.auto_exposure_max_sensitivity = 126.0
        cam_attr.auto_exposure_speed = 0.2
        # LUT 调色 (原版 cc_dust2, contribution 1.0)
        var lut := DLSourceContent.build_lut_texture()
        if lut != null:
                environment.adjustment_enabled = true
                environment.adjustment_color_correction = lut
                environment.adjustment_brightness = 1.0
                environment.adjustment_contrast = 1.0
                environment.adjustment_saturation = 1.0
        we.environment = environment
        add_child(we)
        # 4) 反射探针 (原版 CaptureReflection: (10,3,50) 125×35×125 box 投影)
        var probe := ReflectionProbe.new()
        probe.position = Vector3(10, 3, 50)
        probe.size = Vector3(125, 35, 125)
        probe.update_mode = ReflectionProbe.UPDATE_ONCE
        probe.intensity = 0.45
        add_child(probe)
        # 5) 轻量 SSAO 补充原版烘焙 AO 缺失的顶点光照面
        environment.ssao_enabled = true
        environment.ssao_radius = 0.8
        environment.ssao_intensity = 1.2

func vignette_overlay() -> void:
        ## 原版 Vignette 0.09 — 由 HUD CanvasLayer 调用
        pass

func set_body_visible(player_id: int, vis: bool) -> void:
        if body_nodes.has(player_id):
                body_nodes[player_id].visible = vis

func add_body(player_id: int, node: Node3D) -> void:
        body_nodes[player_id] = node
        add_child(node)

func remove_body(player_id: int) -> void:
        if body_nodes.has(player_id):
                body_nodes[player_id].queue_free()
                body_nodes.erase(player_id)

func spawn_body(p) -> void:
    ## bot 第三人称: 真实人物骨架 (t_leet / ct_idf) + 武器世界模型
    var rig_name := "t_leet" if p.team == 1 else "ct_idf"
    var rig := rig_content.instantiate(rig_name)
    if rig == null:
        return
    rig.name = "bot_%d" % p.id
    rig.set_meta("player_id", p.id)
    rig.set_meta("rig_name", rig_name)
    add_child(rig)
    body_nodes[p.id] = rig
    _attach_world_weapon(p, rig)

func _attach_world_weapon(p, rig: Node3D) -> void:
    var wd := DLWeapons.get_weapon(p.gun)
    var key: String = wd.get("key", "")
    var world_rig_name := key + "_world"
    if not ResourceLoader.exists("res://assets/content/rig_scenes/" + world_rig_name + ".scn"):
        return
    var skel := rig.find_child("Skeleton3D", true, false)
    if skel == null:
        return
    var hand_idx := -1
    for i in skel.get_bone_count():
        var bn: String = skel.get_bone_name(i).to_lower()
        if bn.contains("r_hand") or bn.contains("hand"):
            hand_idx = i
            break
    if hand_idx < 0:
        return
    var ba := BoneAttachment3D.new()
    ba.name = "weapon_attach"
    ba.bone_idx = hand_idx
    skel.add_child(ba)
    var wr: Node3D = rig_content.instantiate(world_rig_name)
    if wr:
        ba.add_child(wr)

func update_body(p, cam_pos: Vector3 = Vector3.ZERO) -> void:
    if not body_nodes.has(p.id):
        return
    var body: Node3D = body_nodes[p.id]
    body.visible = p.alive()
    body.position = p.position
    body.rotation.y = deg_to_rad(p.yaw + 180.0)
    # 步态动画: 速度/朝向/蹲伏选择 locomotion 剪辑
    var ap: AnimationPlayer = body.find_child("AnimationPlayer", true, false)
    if ap == null:
        return
    var speed := Vector2(p.velocity.x, p.velocity.z).length()
    var clip := "a_restand"
    if not p.grounded:
        clip = "a_jump_onspot"
    elif speed < 0.3:
        clip = "a_restand"
    elif p.crouched:
        clip = "a_move_crouchwalkn"
    else:
        clip = "a_move_runn" if speed > 3.0 else "a_move_walkn"
    if speed >= 0.3 and not p.crouched:
        var vel: Vector3 = p.velocity.normalized()
        var ang := rad_to_deg(atan2(vel.x, -vel.z) - deg_to_rad(p.yaw))
        ang = fmod(ang + 540.0, 360.0) - 180.0
        var base := "a_move_run" if speed > 3.0 else "a_move_walk"
        if ang > 45.0 and ang <= 135.0:
            clip = base + "e"
        elif ang < -45.0 and ang >= -135.0:
            clip = base + "w"
        elif ang > 135.0 or ang < -135.0:
            clip = base + "s"
    var cname := clip.to_lower()
    var best := ""
    for a in ap.get_animation_list():
        if String(a).to_lower() == cname:
            best = a
            break
    if best == "":
        for a in ap.get_animation_list():
            if String(a).to_lower().begins_with(cname.substr(0, mini(10, cname.length()))):
                best = a
                break
    if best != "" and ap.current_animation != best:
        ap.play(best, 0.2)
