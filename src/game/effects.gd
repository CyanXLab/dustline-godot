extends Node
## 特效库 Fx (autoload): 弹道曳光/命中/枪口焰/烟雾/火焰/闪光
var world: Node3D = null

const TRACER_LIFE := 0.06
const IMPACT_LIFE := 0.35

var _mat_tracer: StandardMaterial3D
var _mat_spark: StandardMaterial3D
var _mat_smoke: StandardMaterial3D
var _mat_fire: StandardMaterial3D

func _ready() -> void:
        _mat_tracer = StandardMaterial3D.new()
        _mat_tracer.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        _mat_tracer.albedo_color = Color(1.0, 0.85, 0.5, 0.85)
        _mat_tracer.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
        _mat_spark = StandardMaterial3D.new()
        _mat_spark.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        _mat_spark.albedo_color = Color(1.0, 0.75, 0.3)
        _mat_smoke = StandardMaterial3D.new()
        _mat_smoke.albedo_color = Color(0.82, 0.82, 0.8, 0.92)
        _mat_smoke.roughness = 1.0
        _mat_fire = StandardMaterial3D.new()
        _mat_fire.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        _mat_fire.albedo_color = Color(1.0, 0.45, 0.1, 0.8)
        _mat_fire.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

func set_world(w: Node3D) -> void:
        world = w

func _spawn(mesh: Mesh, mat: Material, pos: Vector3, life: float) -> MeshInstance3D:
        if world == null:
                return null
        var mi := MeshInstance3D.new()
        mi.mesh = mesh
        mi.material_override = mat
        world.add_child(mi)
        mi.global_position = pos
        var t := get_tree().create_timer(life)
        t.timeout.connect(func():
                if is_instance_valid(mi):
                        mi.queue_free())
        return mi

func tracer(from: Vector3, to: Vector3) -> void:
        var dir := to - from
        var len := dir.length()
        if len < 0.5:
                return
        var mesh := CylinderMesh.new()
        mesh.top_radius = 0.012
        mesh.bottom_radius = 0.012
        mesh.height = len
        var mi := _spawn(mesh, _mat_tracer, (from + to) / 2.0, TRACER_LIFE)
        if mi != null:
                var mid := dir.normalized()
                if absf(mid.y) < 0.999:
                        mi.global_transform.basis = Basis.looking_at(mid, Vector3.UP)
                else:
                        mi.global_transform.basis = Basis.looking_at(mid, Vector3.RIGHT)
                mi.rotate_object_local(Vector3.RIGHT, PI / 2)

func impact(pos: Vector3, normal: Vector3, material: int) -> void:
        var mesh := SphereMesh.new()
        mesh.radius = 0.05
        mesh.height = 0.1
        var col := Color(1, 0.8, 0.4)
        match material:
                DL.Surface.METAL: col = Color(1, 0.95, 0.7)
                DL.Surface.FLESH: col = Color(0.7, 0.1, 0.1)
                DL.Surface.WOOD: col = Color(0.7, 0.5, 0.25)
                DL.Surface.SAND: col = Color(0.8, 0.7, 0.45)
                DL.Surface.GLASS: col = Color(0.8, 0.95, 1.0)
        var m := StandardMaterial3D.new()
        m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        m.albedo_color = col
        _spawn(mesh, m, pos + normal * 0.03, IMPACT_LIFE)

func muzzle_flash(pos: Vector3) -> void:
        var light := OmniLight3D.new()
        light.light_color = Color(1.0, 0.7, 0.35)
        light.light_energy = 3.0
        light.omni_range = 6.0
        if world != null:
                world.add_child(light)
                light.global_position = pos
                var t := get_tree().create_timer(0.05)
                t.timeout.connect(func():
                        if is_instance_valid(light):
                                light.queue_free())

func explosion(pos: Vector3, big := false) -> void:
        var scale_v := 2.0 if big else 1.0
        var mesh := SphereMesh.new()
        mesh.radius = 1.2 * scale_v
        mesh.height = 2.4 * scale_v
        var mi := _spawn(mesh, _mat_fire, pos, 0.5)
        if mi != null:
                var tw := create_tween()
                mi.scale = Vector3.ONE * 0.3
                tw.tween_property(mi, "scale", Vector3.ONE * scale_v, 0.25)
        var light := OmniLight3D.new()
        light.light_color = Color(1, 0.55, 0.2)
        light.light_energy = 8.0 * scale_v
        light.omni_range = 18.0 * scale_v
        if world != null:
                world.add_child(light)
                light.global_position = pos
                var t2 := get_tree().create_timer(0.4)
                t2.timeout.connect(func():
                        if is_instance_valid(light):
                                light.queue_free())

func smoke_cloud(pos: Vector3, life: float) -> Node3D:
        if world == null:
                return null
        var root := Node3D.new()
        world.add_child(root)
        root.global_position = pos
        for i in 9:
                var mesh := SphereMesh.new()
                mesh.radius = 1.6 + randf() * 0.9
                mesh.height = (1.6 + randf() * 0.9) * 2
                var mi := MeshInstance3D.new()
                mi.mesh = mesh
                mi.material_override = _mat_smoke
                root.add_child(mi)
                mi.position = Vector3(randf_range(-1.2, 1.2), randf_range(0.3, 1.6), randf_range(-1.2, 1.2))
        var t := get_tree().create_timer(life)
        t.timeout.connect(func():
                if is_instance_valid(root):
                        var tw := create_tween()
                        tw.tween_property(root, "scale", Vector3(0.05, 0.05, 0.05), 1.5)
                        tw.tween_callback(root.queue_free))
        return root

func fire_zone(pos: Vector3, life: float) -> Node3D:
        if world == null:
                return null
        var root := Node3D.new()
        world.add_child(root)
        root.global_position = pos
        var light := OmniLight3D.new()
        light.light_color = Color(1, 0.4, 0.1)
        light.light_energy = 3.0
        light.omni_range = 8.0
        root.add_child(light)
        for i in 7:
                var mesh := SphereMesh.new()
                mesh.radius = 0.45 + randf() * 0.3
                mesh.height = (0.45 + randf() * 0.3) * 2
                var mi := MeshInstance3D.new()
                mi.mesh = mesh
                mi.material_override = _mat_fire
                root.add_child(mi)
                mi.position = Vector3(randf_range(-2.2, 2.2), 0.25, randf_range(-2.2, 2.2))
        var t := get_tree().create_timer(life)
        t.timeout.connect(func():
                if is_instance_valid(root):
                        root.queue_free())
        return root

func grenade_mesh(gun: int) -> MeshInstance3D:
        var mi := MeshInstance3D.new()
        var mesh := SphereMesh.new()
        mesh.radius = 0.09
        mesh.height = 0.18
        mi.mesh = mesh
        var m := StandardMaterial3D.new()
        match gun:
                DL.FLASH: m.albedo_color = Color(0.7, 0.7, 0.75)
                DL.HE: m.albedo_color = Color(0.35, 0.45, 0.3)
                DL.SMOKE: m.albedo_color = Color(0.6, 0.6, 0.62)
                DL.MOLOTOV: m.albedo_color = Color(0.7, 0.35, 0.1)
                DL.INCENDIARY: m.albedo_color = Color(0.75, 0.3, 0.1)
                DL.DECOY: m.albedo_color = Color(0.4, 0.4, 0.45)
                _: m.albedo_color = Color(0.5, 0.5, 0.5)
        m.metallic = 0.6
        m.roughness = 0.4
        mi.material_override = m
        return mi
