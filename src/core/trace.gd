class_name DLTrace extends RefCounted
## MovementTrace（移植 MovementTrace.cs）: 对世界 AABB 和玩家圆柱的扫掠
const SKIN := 0.001

static func sweep(map: DLMap, mover: DLPlayer, start: Vector3, delta: Vector3, h: float, others: Array) -> Dictionary:
        var w := world(map, start, delta, h)
        if w.start_solid:
                return w
        var pl := players(mover, start, delta, h, others)
        if not pl.start_solid and not (pl.fraction < w.fraction):
                return w
        return pl

static func clear(map: DLMap, mover: DLPlayer, feet: Vector3, h: float, others: Array) -> bool:
        if map.clear_at(feet, h):
                return not players(mover, feet, Vector3.ZERO, h, others).start_solid
        return false

static func world(map: DLMap, start: Vector3, delta: Vector3, h: float) -> Dictionary:
        ## 原版 MovementTrace.World: SourceWorld 存在时直接 hull 扫掠
        var t := map.world.sweep(start, delta, DL.RADIUS, h, 1)
        return {"fraction": t.fraction, "exit": t.exit_frac, "hit": t.hit,
                "start_solid": t.start_solid, "normal": t.normal, "material": t.material,
                "penetration": t.penetration, "hull": t.hull_index}

static func players(mover: DLPlayer, start: Vector3, delta: Vector3, h: float, others: Array) -> Dictionary:
        var result := {"fraction": 1.0, "exit": 1.0, "hit": false, "start_solid": false,
                "normal": Vector3.ZERO, "material": DL.Surface.STONE, "penetration": 0.0, "hull": -1}
        if others == null:
                return result
        const PAD := 0.8118
        for p in others:
                var op: DLPlayer = p
                if op != null and op.alive() and op.id != mover.id:
                        var mn := op.position - Vector3(PAD, h - 0.001, PAD)
                        var mx := op.position + Vector3(PAD, op.height() - 0.001, PAD)
                        var t := _box(start, delta, mn, mx)
                        t.hull = -1000 - op.id
                        if t.start_solid:
                                return t
                        if t.fraction < result.fraction:
                                result = t
        return result

static func is_player_hit(hull: int) -> bool:
        return hull <= -1000

static func player_id(hull: int) -> int:
        return -hull - 1000

static func _box(start: Vector3, delta: Vector3, mn: Vector3, mx: Vector3) -> Dictionary:
        var fraction := 1.0
        var exit_v := 1.0
        var t_enter := -INF
        var t_exit := INF
        var dist_enter := INF
        var normal := Vector3.ZERO
        var normal_exit := Vector3.ZERO
        var start_solid := true
        for i in 3:
                var o: float = start[i]
                var d: float = delta[i]
                var lo: float = mn[i]
                var hi: float = mx[i]
                var below := o - lo
                var above := hi - o
                var axis := Vector3.ZERO
                axis[i] = 1.0
                if below <= 1e-5 or above <= 1e-5:
                        start_solid = false
                if below < dist_enter:
                        dist_enter = below
                        normal_exit = -axis
                if above < dist_enter:
                        dist_enter = above
                        normal_exit = axis
                if absf(d) < 1e-8:
                        if o < lo or o > hi:
                                return {"fraction": 1.0, "exit": 1.0, "hit": false, "start_solid": false,
                                        "normal": Vector3.ZERO, "material": DL.Surface.STONE, "penetration": 0.0, "hull": -1}
                        continue
                var t0 := (lo - o) / d
                var t1 := (hi - o) / d
                var n := -axis
                if t0 > t1:
                        var tmp := t0; t0 = t1; t1 = tmp
                        n = axis
                if t0 > t_enter:
                        t_enter = t0
                        normal = n
                t_exit = minf(t_exit, t1)
                if t_enter > t_exit:
                        return {"fraction": 1.0, "exit": 1.0, "hit": false, "start_solid": false,
                                "normal": Vector3.ZERO, "material": DL.Surface.STONE, "penetration": 0.0, "hull": -1}
        if start_solid:
                return {"fraction": 0.0, "exit": maxf(0.0, t_exit), "hit": true, "start_solid": true,
                        "normal": normal_exit, "material": DL.Surface.STONE, "penetration": dist_enter, "hull": -1}
                # 用进入轴速度计算 skin 退缩
                var speed := maxf(1e-5, absf(_max_axis(delta)))
                return {"fraction": maxf(0.0, t_enter - 0.001 / speed), "exit": t_exit, "hit": true,
                        "start_solid": false, "normal": normal, "material": DL.Surface.STONE, "penetration": 0.0, "hull": -1}
        return {"fraction": 1.0, "exit": 1.0, "hit": false, "start_solid": false,
                "normal": Vector3.ZERO, "material": DL.Surface.STONE, "penetration": 0.0, "hull": -1}

static func _max_axis(v: Vector3) -> float:
        return maxf(absf(v.x), maxf(absf(v.y), absf(v.z)))
