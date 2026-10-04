extends SceneTree
func _init() -> void:
	var w := DLSourceWorld.new("res://assets/content/world.dsw", "res://assets/content/terrain.dst")
	print("hulls=", w.hulls.size(), " areas=", w.areas.size(), " spawns=", w.spawns.size(), " volumes=", w.volumes.size())
	print("bvh nodes=", w._n_min.size(), " nav nodes=", w._nav_bmin.size())
	print("depth=", _depth(w, 0))
	var t := w.sweep(Vector3(0, 2, 28), Vector3(0, -3, 0), 0.4064, 1.8288, 1)
	print("sweep down @CT spawn: hit=", t.hit, " frac=", t.fraction, " start_solid=", t.start_solid, " normal=", t.normal)
	var t2 := w.sweep(Vector3(0, 1.7, 28), Vector3(1, 0, 0), 0.0, 0.0, 2)
	print("ray +x: hit=", t2.hit, " frac=", t2.fraction)
	var walls := w.bullet_walls(Vector3(0, 1.7, 28), Vector3(1, 0, 0), 100.0)
	print("walls=", walls.size())
	for wp in mini(3, walls.size()):
		print("  wall enter=", walls[wp].enter_frac, " exit=", walls[wp].exit_frac, " surf=", walls[wp].enter_surface)
	quit()

func _depth(w: DLSourceWorld, idx: int) -> int:
	var d: PackedInt32Array = w._n_data
	if idx * 5 + 4 >= d.size():
		return 0
	if d[idx * 5 + 3] == 0:
		return 1 + maxi(_depth(w, d[idx * 5]), _depth(w, d[idx * 5 + 1]))
	return 0
