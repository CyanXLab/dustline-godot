class_name DLSourceWorld extends RefCounted
## SourceWorld 逐行移植 (core/Dustline.Core/SourceWorld.cs + Solid.cs + GrenadeCollision.cs
## + BallisticSurface.cs + SourceSurfaceData.cs)
## 真实 dust2 碰撞 hull / 出生点 / 包点 volume / 导航 area / 弹道表面 — 全部来自原版数据。
## 单位: 米 (与 DL 常量一致)。数据文件: assets/content/world.dsw + terrain.dst (zstd)

const R_EPS := 0.001            # Sweep 收缩
const PLANE_EPS := 0.002        # Clip 距离容差
const GRENADE_UNIT := 0.0254
const GRENADE_HALF := 0.0508
const GRENADE_EPS := 0.00079375
const SOLID_CONTENTS := 34095115
const FLIGHT_CONTENTS := 1107845259
const DEBRIS_CONTENTS := 540683

# 表面材质字符 → DL.Surface
const MAT_CHAR := {87: 1, 77: 2, 86: 2, 89: 3, 71: 4, 76: 5, 85: 6, 78: 7, 70: 8}  # W/M/V/Y/G/L/U/N/F

const SURFACE_TABLE := [
        ["default", 67, 1.0, 0.5], ["solidmetal", 77, 0.27, 0.3], ["metal", 77, 0.4, 0.3],
        ["metalgrate", 71, 0.95, 0.99], ["grate", 71, 0.95, 0.99], ["metalvent", 86, 0.6, 0.45],
        ["metalpanel", 86, 0.5, 0.45], ["dirt", 68, 0.6, 0.3], ["grass", 74, 0.6, 0.3],
        ["tile", 84, 0.7, 0.3], ["wood", 87, 0.9, 0.6], ["wood_plank", 87, 0.85, 0.6],
        ["wood_solid", 87, 0.8, 0.6], ["wood_dense", 13, 0.5, 0.3], ["water", 83, 0.3, 0.5],
        ["glass", 89, 0.99, 0.5], ["computer", 80, 0.4, 0.45], ["concrete", 67, 0.5, 0.25],
        ["asphalt", 81, 0.55, 0.3], ["rock", 3, 0.5, 0.25], ["brick", 82, 0.47, 0.25],
        ["stucco", 2, 0.5, 0.25], ["sand", 78, 0.5, 0.25], ["flesh", 70, 1.0, 0.5],
        ["cardboard", 85, 0.95, 0.5], ["plastic", 76, 0.8, 0.5],
]

class Trace:
        var fraction := 1.0
        var exit_frac := 1.0
        var penetration := 0.0
        var leave := 0.0
        var normal := Vector3.ZERO
        var material: int = 0        # DL.Surface
        var start_solid := false
        var all_solid := false
        var hull_index := -1
        var surface_index := -1
        var surface_flags := 0
        var box_brush := false
        var get_out := false
        var player_id := -1
        var grenade_id := 0
        var hit: bool:
                get:
                        return fraction < 1.0

        func to_dict() -> Dictionary:
                return {"fraction": fraction, "exit": exit_frac, "penetration": penetration,
                        "leave": leave, "normal": normal, "material": material,
                        "start_solid": start_solid, "all_solid": all_solid, "hull_index": hull_index,
                        "surface_index": surface_index, "surface_flags": surface_flags, "hit": hit}

class BulletWall:
        var enter_frac := 0.0
        var exit_frac := 0.0
        var enter_surface: int = 0
        var exit_surface: int = 0
        var contents := 0
        var enter_flags := 0
        var exit_flags := 0

class Hull:
        var bmin := Vector3.ZERO
        var bmax := Vector3.ZERO
        var mask := 0
        var contents := 1
        var material: int = 0
        var planes := PackedFloat32Array()      # 4 floats/plane (nx,ny,nz,d)
        var plane_count := 0
        var original_plane_count := 0
        var plane_flags := PackedInt32Array()   # 每平面, 可为空
        var plane_bevels := PackedByteArray()
        var plane_surfaces := PackedInt32Array()
        var bullet_surface := -1                # 表面表索引

        func plane_dot(i: int, p: Vector3) -> float:
                var o := i * 4
                return planes[o] * p.x + planes[o + 1] * p.y + planes[o + 2] * p.z - planes[o + 3]

        func support(i: int, e: Vector3) -> float:
                var o := i * 4
                return absf(planes[o]) * e.x + absf(planes[o + 1]) * e.y + absf(planes[o + 2]) * e.z

class Area:
        var id := 0
        var attributes := 0
        var nw := Vector3.ZERO
        var se := Vector3.ZERO
        var ne := 0.0
        var sw := 0.0
        var links := PackedInt32Array()

        func point(x: float, z: float) -> Vector3:
                x = clampf(x, nw.x, se.x)
                z = clampf(z, nw.z, se.z)
                var u := (x - nw.x) / maxf(0.0001, se.x - nw.x)
                var v := (z - nw.z) / maxf(0.0001, se.z - nw.z)
                return Vector3(x, (nw.y * (1.0 - u) + ne * u) * (1.0 - v) + (sw * (1.0 - u) + se.y * u) * v, z)

        func center() -> Vector3:
                return Vector3((nw.x + se.x) * 0.5, 0.0, (nw.z + se.z) * 0.5)

# ---- 数据 ----
var hulls: Array[Hull] = []
var spawns: Array = []            # {team, position, yaw, priority, enabled}
var volumes: Array = []           # {kind, bmin, bmax}
var areas: Array[Area] = []
var world_min := Vector3.ZERO
var world_max := Vector3.ZERO
var surfaces: Array = []          # {name, gm, pen, dmg, kind}

var _order := PackedInt32Array()
var _n_min := PackedVector3Array()
var _n_max := PackedVector3Array()
var _n_data := PackedInt32Array()   # [left, right, start, count, mask]

var _nav_order := PackedInt32Array()
var _nav_bmin := PackedVector3Array()
var _nav_bmax := PackedVector3Array()
var _nav_data := PackedInt32Array()
# BVH 节点专用 (与 area 边界数组分离)
var _nn_min := PackedVector3Array()
var _nn_max := PackedVector3Array()
var _nn_data := PackedInt32Array()
var _nav_center := PackedVector3Array()
var _nav_dist: Array = []          # Array of PackedFloat32Array

# 寻路工作集 (单线程核心, 无锁)
var _pf_cost := PackedFloat64Array()
var _pf_score := PackedFloat64Array()
var _pf_h := PackedFloat64Array()
var _pf_prev := PackedInt32Array()
var _pf_heap := PackedInt32Array()
var _pf_hpos := PackedInt32Array()
var _pf_closed := PackedByteArray()
var _pf_count := 0

static func decompress(src_path: String) -> PackedByteArray:
        var f := FileAccess.open(src_path, FileAccess.READ)
        if f == null:
                push_error("缺失内容文件: " + src_path)
                return PackedByteArray()
        var raw: PackedByteArray = f.get_buffer(f.get_length())
        f.close()
        if raw.slice(0, 4).get_string_from_ascii() != "DLZ1":
                push_error("内容文件缺少 DLZ1 头: " + src_path)
                return PackedByteArray()
        var usize := raw.decode_u64(4)
        return raw.slice(12).decompress(usize, 1)  # 1 = COMPRESSION_DEFLATE(zlib流)

func _init(world_zst: String, terrain_zst: String) -> void:
        var w := decompress(world_zst)
        var t := decompress(terrain_zst) if terrain_zst != "" else PackedByteArray()
        _parse_world(w)
        if t.size() > 0:
                _parse_terrain(t)
        _build_bvh()
        _build_navigation_index()

func _surface_kind(gm: int) -> int:
        return MAT_CHAR.get(gm, 0)

# ================= 解析 =================
func _parse_world(b: PackedByteArray) -> void:
        var s := StreamPeerBuffer.new()
        s.data_array = b
        s.big_endian = false
        if s.get_u32() != 827806532:
                push_error("world.dsw 魔数不符")
                return
        var hull_count := s.get_32()
        hulls.resize(hull_count)
        for i in hull_count:
                var h := Hull.new()
                h.bmin = Vector3(s.get_float(), s.get_float(), s.get_float())
                h.bmax = Vector3(s.get_float(), s.get_float(), s.get_float())
                h.mask = s.get_u8()
                h.contents = 1 if (h.mask & 2) != 0 else (524288 if (h.mask & 4) != 0 else 65536)
                h.material = s.get_u8()
                var pc := s.get_u16()
                h.original_plane_count = pc
                var flat := PackedFloat32Array()
                flat.resize(pc * 4)
                for j in pc:
                        flat[j * 4] = s.get_float()
                        flat[j * 4 + 1] = s.get_float()
                        flat[j * 4 + 2] = s.get_float()
                        flat[j * 4 + 3] = s.get_float()
                # 加包围盒轴向 bevel 平面 (构造函数逻辑)
                var extra: Array[float] = []
                for axis in 3:
                        for l in [-1, 1]:
                                var comp_max: float = h.bmax[axis] if l > 0 else -h.bmin[axis]
                                var dirv := Vector3.ZERO
                                dirv[axis] = float(l)
                                var found := false
                                for j in pc + extra.size() / 4:
                                        var o := j * 4
                                        var eo := o - pc * 4
                                        var nx := flat[o] if j < pc else extra[eo]
                                        var ny := flat[o + 1] if j < pc else extra[eo + 1]
                                        var nz := flat[o + 2] if j < pc else extra[eo + 2]
                                        var dd := flat[o + 3] if j < pc else extra[eo + 3]
                                        if nx * dirv.x + ny * dirv.y + nz * dirv.z > 0.99999 and dd <= comp_max + 0.0001:
                                                found = true
                                                break
                                if not found:
                                        extra.append_array([dirv.x, dirv.y, dirv.z, comp_max])
                flat.append_array(PackedFloat32Array(extra))
                h.planes = flat
                h.plane_count = flat.size() / 4
                hulls[i] = h
        # 出生点
        var spawn_count := s.get_32()
        spawns.resize(spawn_count)
        for i in spawn_count:
                var team := s.get_u8()
                var pos := Vector3(s.get_float(), s.get_float(), s.get_float())
                var yaw := s.get_float()
                spawns[i] = {"team": team, "position": pos, "yaw": yaw, "priority": 0, "enabled": true}
        # Volume (包点/购买区)
        var vol_count := s.get_32()
        volumes.resize(vol_count)
        for i in vol_count:
                var kind := s.get_u8()
                var mn := Vector3(s.get_float(), s.get_float(), s.get_float())
                var mx := Vector3(s.get_float(), s.get_float(), s.get_float())
                volumes[i] = {"kind": kind, "bmin": mn, "bmax": mx}
        # 导航 Area
        var area_count := s.get_32()
        areas.resize(area_count)
        var id_map := {}
        for i in area_count:
                var a := Area.new()
                a.id = s.get_u32()
                a.attributes = s.get_u32()
                a.nw = Vector3(s.get_float(), s.get_float(), s.get_float())
                a.se = Vector3(s.get_float(), s.get_float(), s.get_float())
                a.ne = s.get_float()
                a.sw = s.get_float()
                var lc := s.get_32()
                var links := PackedInt32Array()
                links.resize(lc)
                for j in lc:
                        links[j] = s.get_32()
                a.links = links
                areas[i] = a
                id_map[a.id] = i
        for a in areas:
                for j in a.links.size():
                        a.links[j] = id_map.get(a.links[j], -1)
        # 元数据块
        while s.get_available_bytes() >= 4:
                var tag := s.get_u32()
                if tag == 827805779:  # 出生点元数据
                        var n := s.get_32()
                        for i in n:
                                var sp: Dictionary = spawns[i]
                                sp.priority = s.get_32()
                                sp.enabled = s.get_u8() != 0
                elif tag == 827605325:  # 弹道表面表
                        var sn := s.get_u16()
                        surfaces.resize(sn)
                        for i in sn:
                                var nl := s.get_u16()
                                var name := s.get_string(nl)
                                var gm := s.get_u8()
                                var pen := s.get_float()
                                var dmg := s.get_float()
                                surfaces[i] = {"name": name, "gm": gm, "pen": pen, "dmg": dmg, "kind": _surface_kind(gm)}
                        var hcn := s.get_32()
                        for i in hcn:
                                var h: Hull = hulls[i]
                                h.contents = s.get_u32()
                                var sidx := s.get_u16()
                                var pcnt := s.get_u16()
                                h.bullet_surface = sidx
                                if sidx >= 0 and sidx < sn:
                                        h.material = surfaces[sidx].kind
                                var ps := PackedInt32Array()
                                ps.resize(h.plane_count)
                                for k in pcnt:
                                        ps[k] = s.get_u16()
                                for k in range(pcnt, h.plane_count):
                                        ps[k] = sidx
                                h.plane_surfaces = ps
                elif tag == 826756166:  # 平面标志
                        var hcn2 := s.get_32()
                        for i in hcn2:
                                var h2: Hull = hulls[i]
                                var cnt := s.get_u16()
                                if cnt != 0:
                                        var fl := PackedInt32Array()
                                        fl.resize(h2.plane_count)
                                        for k in cnt:
                                                fl[k] = s.get_u16()
                                        h2.plane_flags = fl
                elif tag == 827086402:  # bevel 标志
                        var hcn3 := s.get_32()
                        for i in hcn3:
                                var h3: Hull = hulls[i]
                                var cnt3 := s.get_u16()
                                if cnt3 != 0:
                                        var bv := PackedByteArray()
                                        bv.resize(h3.plane_count)
                                        for k in cnt3:
                                                bv[k] = s.get_u8()
                                        for k in range(cnt3, h3.plane_count):
                                                bv[k] = 1
                                        h3.plane_bevels = bv
                else:
                        push_error("未知 world 元数据块 %d" % tag)
                        break

func _parse_terrain(b: PackedByteArray) -> void:
        var s := StreamPeerBuffer.new()
        s.data_array = b
        s.big_endian = false
        if s.get_u32() != 827609924:
                push_error("terrain.dst 魔数不符")
                return
        var n := s.get_32()
        var list: Array[Hull] = []
        list.assign(hulls)
        for i in n:
                var v1 := Vector3(s.get_float(), s.get_float(), s.get_float())
                var v2 := Vector3(s.get_float(), s.get_float(), s.get_float())
                var v3 := Vector3(s.get_float(), s.get_float(), s.get_float())
                var nrm := (v2 - v1).cross(v3 - v1).normalized()
                if nrm.length() < 0.9:
                        continue
                var eps := Vector3(absf(nrm.x), absf(nrm.y), absf(nrm.z)) * 0.008
                var h := Hull.new()
                h.mask = 3
                h.bmin = v1.min(v2.min(v3)) - eps
                h.bmax = v1.max(v2.max(v3)) + eps
                var flat := PackedFloat32Array()
                flat.append_array([nrm.x, nrm.y, nrm.z, nrm.dot(v1) + 0.008])
                flat.append_array([-nrm.x, -nrm.y, -nrm.z, -nrm.dot(v1) + 0.008])
                var tri := [v1, v2, v3]
                for k in 3:
                        var e: Vector3 = (tri[(k + 1) % 3] - tri[k]).cross(nrm).normalized()
                        flat.append_array([e.x, e.y, e.z, e.dot(tri[k])])
                for k in 3:
                        var ax := Vector3.ZERO
                        ax[k] = 1.0
                        flat.append_array([ax.x, ax.y, ax.z, h.bmax[k]])
                        flat.append_array([-ax.x, -ax.y, -ax.z, -h.bmin[k]])
                # 边-轴 bevel 平面
                var edge_list := [v2 - v1, v3 - v2, v1 - v3, nrm]
                var exists: Array = []
                for e0 in [flat]:
                        pass
                for ei in edge_list.size():
                        var a: Vector3 = edge_list[ei]
                        for axis in 3:
                                var axv := Vector3.ZERO
                                axv[axis] = 1.0
                                var c := a.cross(axv)
                                if c.length() < 0.9:
                                        continue
                                c = c.normalized()
                                for l in [-1, 1]:
                                        var dirv := c * float(l)
                                        var d := maxf(dirv.dot(v1), maxf(dirv.dot(v2), dirv.dot(v3))) + 0.008 * absf(dirv.dot(nrm))
                                        var dup := false
                                        var total := flat.size() / 4
                                        for j in total:
                                                var o := j * 4
                                                if flat[o] * dirv.x + flat[o + 1] * dirv.y + flat[o + 2] * dirv.z > 0.99999 and flat[o + 3] <= d + 0.0001:
                                                        dup = true
                                                        break
                                        if not dup:
                                                flat.append_array([dirv.x, dirv.y, dirv.z, d])
                h.planes = flat
                h.plane_count = flat.size() / 4
                h.original_plane_count = h.plane_count
                list.append(h)
        hulls = list

# ================= BVH =================
func _build_bvh() -> void:
        _order.resize(hulls.size())
        for i in hulls.size():
                _order[i] = i
        _build_node(0, hulls.size())

func _build_node(start: int, count: int) -> int:
        var idx := _n_min.size()
        var bmin := Vector3(1e30, 1e30, 1e30)
        var bmax := -bmin
        var mask := 0
        for i in range(start, start + count):
                var h: Hull = hulls[_order[i]]
                bmin = bmin.min(h.bmin)
                bmax = bmax.max(h.bmax)
                mask |= h.mask
        _n_min.append(bmin)
        _n_max.append(bmax)
        _n_data.append_array([0, 0, start, count, mask])
        if count > 8:
                var size := bmax - bmin
                var axis := 0 if (size.x > size.y and size.x > size.z) else (1 if size.y > size.z else 2)
                var slice: Array = Array(_order.slice(start, start + count))
                slice.sort_custom(func(a, b) -> bool:
                        var ca: float = hulls[a].bmin[axis] + hulls[a].bmax[axis]
                        var cb: float = hulls[b].bmin[axis] + hulls[b].bmax[axis]
                        return ca < cb)
                for i in count:
                        _order[start + i] = int(slice[i])
                var mid := count / 2
                var left := _build_node(start, mid)
                var right := _build_node(start + mid, count - mid)
                _n_data[idx * 5] = left
                _n_data[idx * 5 + 1] = right
                _n_data[idx * 5 + 3] = 0
        return idx

func _touches(a_min: Vector3, a_max: Vector3, b_min: Vector3, b_max: Vector3) -> bool:
        return a_min.x <= b_max.x and a_max.x >= b_min.x and a_min.y <= b_max.y \
                and a_max.y >= b_min.y and a_min.z <= b_max.z and a_max.z >= b_min.z

func _expanded_slab(o: float, d: float, mn: float, mx: float, ent: Array, lve: Array) -> bool:
        if absf(d) < 1e-7:
                return o >= mn and o <= mx
        var t1 := (mn - o) / d
        var t2 := (mx - o) / d
        if t1 > t2:
                var t := t1
                t1 = t2
                t2 = t
        if t1 > ent[0]:
                ent[0] = t1
        if t2 < lve[0]:
                lve[0] = t2
        return lve[0] >= ent[0]

func _expanded_ray(bmin: Vector3, bmax: Vector3, origin: Vector3, delta: Vector3, ext: Vector3, limit: float) -> bool:
        var ent := [0.0]
        var lve := [limit]
        if not _expanded_slab(origin.x, delta.x, bmin.x - ext.x, bmax.x + ext.x, ent, lve):
                return false
        if not _expanded_slab(origin.y, delta.y, bmin.y - ext.y, bmax.y + ext.y, ent, lve):
                return false
        return _expanded_slab(origin.z, delta.z, bmin.z - ext.z, bmax.z + ext.z, ent, lve)

# ================= 玩家扫掠 =================
func sweep(start: Vector3, delta: Vector3, radius := 0.0, height := 0.0, mask := 1) -> Trace:
        if radius > 0.0:
                radius = maxf(0.0, radius - R_EPS)
                height = maxf(0.0, height - R_EPS)
        var ext := Vector3(radius, height * 0.5, radius)
        start.y += ext.y
        var result := Trace.new()
        result.fraction = 1.0
        result.exit_frac = 1.0
        _query(0, start, delta, ext, mask, result)
        return result

func _query(nidx: int, start: Vector3, delta: Vector3, ext: Vector3, mask: int, result: Trace) -> void:
        var d := _n_data
        if (d[nidx * 5 + 4] & mask) == 0:
                return
        if not _expanded_ray(_n_min[nidx], _n_max[nidx], start, delta, ext, result.fraction):
                return
        if d[nidx * 5 + 3] == 0:
                _query(d[nidx * 5], start, delta, ext, mask, result)
                _query(d[nidx * 5 + 1], start, delta, ext, mask, result)
                return
        for i in range(d[nidx * 5 + 2], d[nidx * 5 + 2] + d[nidx * 5 + 3]):
                var oi := _order[i]
                var h: Hull = hulls[oi]
                if (h.mask & mask) != 0 and _expanded_ray(h.bmin, h.bmax, start, delta, ext, result.fraction):
                        var t := _clip_hull(h, start, delta, ext)
                        t.hull_index = oi
                        if t.start_solid:
                                result.fraction = t.fraction
                                result.exit_frac = t.exit_frac
                                result.penetration = t.penetration
                                result.normal = t.normal
                                result.material = t.material
                                result.start_solid = true
                                result.all_solid = t.all_solid
                                result.hull_index = t.hull_index
                                result.surface_index = t.surface_index
                                result.surface_flags = t.surface_flags
                                result.get_out = t.get_out
                                result.leave = t.leave
                                result.box_brush = t.box_brush
                                return
                        if t.fraction < result.fraction:
                                result.fraction = t.fraction
                                result.exit_frac = t.exit_frac
                                result.normal = t.normal
                                result.material = t.material
                                result.surface_index = t.surface_index
                                result.surface_flags = t.surface_flags
                                result.get_out = t.get_out

func _clip_hull(h: Hull, start: Vector3, delta: Vector3, ext: Vector3) -> Trace:
        var result := Trace.new()
        result.fraction = 1.0
        result.exit_frac = 1.0
        result.material = h.material
        var num := -1.0
        var num2 := 1.0
        var num3 := -1e30
        var normal := Vector3.ZERO
        var normal2 := Vector3.ZERO
        var flag := false
        for i in h.plane_count:
                var o := i * 4
                var nx: float = h.planes[o]
                var ny: float = h.planes[o + 1]
                var nz: float = h.planes[o + 2]
                var dist: float = h.planes[o + 3]
                var nd := nx * start.x + ny * start.y + nz * start.z - dist - (absf(nx) * ext.x + absf(ny) * ext.y + absf(nz) * ext.z)
                var d2 := nx * delta.x + ny * delta.y + nz * delta.z
                var num5 := nd + d2
                if nd > num3:
                        num3 = nd
                        normal2 = Vector3(nx, ny, nz)
                if nd >= -0.0001:
                        flag = true
                if nd > 0.0 and num5 >= nd:
                        return result
                if nd <= 0.0 and num5 <= 0.0:
                        continue
                if nd > num5:
                        var num6 := maxf(0.0, (nd - PLANE_EPS) / (nd - num5))
                        if num6 > num:
                                num = num6
                                normal = Vector3(nx, ny, nz)
                else:
                        num2 = minf(num2, (nd + PLANE_EPS) / (nd - num5))
                if num > num2:
                        return result
        if not flag:
                result.start_solid = true
                result.fraction = 0.0
                result.normal = normal2
                result.penetration = -num3
                return result
        if num >= -0.001 and num < num2:
                result.fraction = maxf(0.0, num)
                result.normal = normal
                result.exit_frac = num2
        return result

# ================= 手雷/实体扫掠 =================
func grenade_sweep(center: Vector3, delta: Vector3, contents: int = FLIGHT_CONTENTS, extent: float = GRENADE_HALF) -> Trace:
        var result := Trace.new()
        result.fraction = 1.0
        result.exit_frac = 1.0
        result.player_id = -1
        result.hull_index = -1
        result.surface_index = -1
        _grenade_query(0, center, delta, Vector3(extent, extent, extent), contents, result)
        return result

func _grenade_query(nidx: int, start: Vector3, delta: Vector3, ext: Vector3, contents: int, result: Trace) -> void:
        var d := _n_data
        var e2 := ext + Vector3(GRENADE_EPS, GRENADE_EPS, GRENADE_EPS)
        if not _expanded_ray(_n_min[nidx], _n_max[nidx], start, delta, e2, result.fraction):
                return
        if d[nidx * 5 + 3] == 0:
                _grenade_query(d[nidx * 5], start, delta, ext, contents, result)
                _grenade_query(d[nidx * 5 + 1], start, delta, ext, contents, result)
                return
        for i in range(d[nidx * 5 + 2], d[nidx * 5 + 2] + d[nidx * 5 + 3]):
                var oi := _order[i]
                var h: Hull = hulls[oi]
                if _contents_match(h, contents) and _expanded_ray(h.bmin, h.bmax, start, delta, e2, result.fraction):
                        var hit := _grenade_clip(h, start, delta, ext)
                        hit.hull_index = oi
                        _merge_trace(result, hit, ext.x == 0.0)
                        if result.all_solid:
                                break

func _contents_match(h: Hull, contents: int) -> bool:
        var m := h.contents & contents
        if m == 0:
                return false
        if m == 128:
                if (contents & 0x2000) == 0 or h.plane_flags.size() == 0:
                        return true
                for i in h.plane_flags.size():
                        if (h.plane_flags[i] & 0x80) != 0:
                                return false
        return true

func _grenade_clip(h: Hull, start: Vector3, delta: Vector3, ext: Vector3) -> Trace:
        var miss := Trace.new()
        miss.fraction = 1.0
        miss.exit_frac = 1.0
        miss.player_id = -1
        miss.hull_index = -1
        miss.surface_index = -1
        var is_box := h.original_plane_count == 6 and h.plane_flags.size() > 0
        if is_box:
                for i in 6:
                        var o := i * 4
                        if absf(h.planes[o]) + absf(h.planes[o + 1]) + absf(h.planes[o + 2]) != 1.0:
                                is_box = false
                                break
        if is_box:
                miss = _gc_box(start, delta, h.bmin, h.bmax, ext.x)
                if delta.length() == 0.0 and miss.start_solid:
                        miss.leave = 1.0
                for j in 6:
                        var o2 := j * 4
                        if h.planes[o2] * miss.normal.x + h.planes[o2 + 1] * miss.normal.y + h.planes[o2 + 2] * miss.normal.z > 0.99999:
                                miss.surface_index = j
                                miss.surface_flags = h.plane_flags[j] if j < h.plane_flags.size() else 0
                                break
                return miss
        # 通用 hull 裁剪 (英寸空间)
        var s := start / GRENADE_UNIT
        var dl := delta / GRENADE_UNIT
        var e := ext / GRENADE_UNIT
        var num := -99999.0
        var num2 := 1.0
        var flag2 := false
        var flag3 := false
        var num3 := -1
        for k in h.plane_count:
                if ext.x == 0.0 and k < h.plane_bevels.size() and h.plane_bevels[k] != 0:
                        continue
                var o := k * 4
                var n := Vector3(h.planes[o], h.planes[o + 1], h.planes[o + 2])
                var dist: float = h.planes[o + 3] / GRENADE_UNIT + (absf(n.x) * e.x + absf(n.y) * e.y + absf(n.z) * e.z)
                var num5 := n.dot(s) - dist
                var num6 := n.dot(s + dl) - dist
                if num5 > 0.0:
                        flag2 = true
                        if num6 > 0.0:
                                return miss
                else:
                        if num6 <= 0.0:
                                continue
                        flag3 = true
                if num5 > num6:
                        var num7 := maxf(0.0, num5 - 1.0 / 32.0) / (num5 - num6)
                        if num7 > num:
                                num = num7
                                num3 = k
                else:
                        num2 = minf(num2, (num5 + 1.0 / 32.0) / (num5 - num6))
        miss.exit_frac = num2
        miss.get_out = flag3
        if not flag2:
                miss.start_solid = true
                miss.all_solid = not flag3
                miss.leave = 1.0 if not flag3 else (0.0 if num2 == 1.0 else maxf(0.0, num2))
                if not flag3:
                        miss.fraction = 0.0
                return miss
        if num < num2 and num > -99999.0 and num < 1.0:
                miss.fraction = maxf(0.0, num)
                var o3 := num3 * 4
                miss.normal = Vector3(h.planes[o3], h.planes[o3 + 1], h.planes[o3 + 2])
                miss.surface_index = num3
                if h.plane_flags.size() > 0 and num3 < h.plane_flags.size():
                        miss.surface_flags = h.plane_flags[num3]
        return miss

## GrenadeCollision.Box 移植 (世界 brush 路径)
func _gc_box(start: Vector3, delta: Vector3, mins: Vector3, maxs: Vector3, extent: float) -> Trace:
        var s := start / GRENADE_UNIT
        var dl := delta / GRENADE_UNIT
        var mn := mins / GRENADE_UNIT
        var mx := maxs / GRENADE_UNIT
        var e := extent / GRENADE_UNIT
        var miss := Trace.new()
        miss.fraction = 1.0
        miss.exit_frac = 1.0
        miss.player_id = -1
        miss.hull_index = -1
        miss.surface_index = -1
        var num := 1.0        # leave
        var num2 := 0.0       # enter
        var num3 := 1.0       # exit
        var num4 := -1e30
        var normal := Vector3.ZERO
        var flag := false
        for i in 3:
                var axis := 2 if i == 1 else (0 if i == 0 else 1)
                var num5: float = (mn[axis] - s[axis]) - e
                var num6: float = (mx[axis] - s[axis]) + e
                var num7: float = dl[axis]
                var f2 := num5 > 0.0
                var f3 := num7 < num5
                var f4 := num6 < 0.0
                var f5 := num7 > num6
                if (f2 and f3) or (f4 and f5):
                        return miss
                flag = flag or f2 or f4
                if f2 != f3 or f4 != f5:
                        var num8 := 1.0 / num7 if num7 != 0.0 else 1e30
                        var val := num5 * num8
                        var val2 := num6 * num8
                        num2 = maxf(num2, minf(val, val2))
                        num = minf(num, maxf(val, val2))
                        val = (num5 - 1.0 / 32.0) * num8
                        val2 = (num6 + 1.0 / 32.0) * num8
                        var num9 := minf(val, val2)
                        if num9 >= num4:
                                num4 = num9
                                var ax := Vector3.ZERO
                                ax[axis] = 1.0 if val <= val2 else -1.0
                                normal = ax
                        num3 = minf(num3, maxf(val, val2))
        if num2 > num:
                return miss
        miss.exit_frac = num3
        miss.box_brush = true
        miss.get_out = num3 < 1.0
        if not flag:
                miss.start_solid = true
                miss.all_solid = num3 >= 1.0
                miss.leave = 0.0 if miss.all_solid else maxf(0.0, num3)
                if miss.all_solid:
                        miss.fraction = 0.0
                return miss
        var num10 := maxf(0.0, num4)
        if num10 <= minf(1.0, num3):
                miss.fraction = num10
                miss.normal = normal
        return miss

## GrenadeCollision.Merge 移植
func _merge_trace(result: Trace, hit: Trace, point := false) -> void:
        if point and result.leave > hit.fraction and not hit.start_solid:
                hit.start_solid = true
                hit.all_solid = not hit.get_out
                hit.leave = (1.0 if not hit.box_brush else 0.0) if hit.all_solid else (0.0 if hit.exit_frac == 1.0 else maxf(0.0, hit.exit_frac))
                hit.fraction = 1.0 if not hit.all_solid else 0.0
        if hit.start_solid and not hit.all_solid and hit.leave > result.leave and result.fraction <= hit.leave:
                result.fraction = 1.0
                result.normal = Vector3.ZERO
                result.surface_flags = 0
        if hit.start_solid and result.fraction >= 1.0:
                result.hull_index = hit.hull_index
                result.exit_frac = hit.exit_frac
        var start_solid := result.start_solid or hit.start_solid
        var leave := maxf(result.leave, hit.leave)
        if hit.all_solid or hit.fraction < result.fraction:
                result.fraction = hit.fraction
                result.exit_frac = hit.exit_frac
                result.penetration = hit.penetration
                result.leave = hit.leave
                result.normal = hit.normal
                result.material = hit.material
                result.start_solid = hit.start_solid
                result.all_solid = hit.all_solid
                result.hull_index = hit.hull_index
                result.surface_index = hit.surface_index
                result.surface_flags = hit.surface_flags
                result.box_brush = hit.box_brush
                result.get_out = hit.get_out
                result.player_id = hit.player_id
                result.grenade_id = hit.grenade_id
        result.start_solid = start_solid
        result.leave = leave

# ================= 弹道穿墙 =================
func bullet_walls(start: Vector3, dir: Vector3, distance: float) -> Array[BulletWall]:
        var result: Array[BulletWall] = []
        _wall_query(0, start, dir, distance, result)
        result.sort_custom(func(a: BulletWall, b: BulletWall) -> bool: return a.enter_frac < b.enter_frac)
        return result

func _wall_query(nidx: int, start: Vector3, dir: Vector3, distance: float, result: Array[BulletWall]) -> void:
        if not _box_ray(_n_min[nidx], _n_max[nidx], start, dir, distance):
                return
        var d := _n_data
        if d[nidx * 5 + 3] == 0:
                _wall_query(d[nidx * 5], start, dir, distance, result)
                _wall_query(d[nidx * 5 + 1], start, dir, distance, result)
                return
        for i in range(d[nidx * 5 + 2], d[nidx * 5 + 2] + d[nidx * 5 + 3]):
                var oi := _order[i]
                var h: Hull = hulls[oi]
                if (h.mask & 2) == 0:
                        continue
                if not _box_ray(h.bmin, h.bmax, start, dir, distance):
                        continue
                var hit := _bullet_trace(h, start, dir, distance)
                if hit != null:
                        result.append(hit)

func _box_ray(bmin: Vector3, bmax: Vector3, origin: Vector3, dir: Vector3, limit: float) -> bool:
        var ent := [0.0]
        var lve := [limit]
        if not _expanded_slab(origin.x, dir.x, bmin.x, bmax.x, ent, lve):
                return false
        if not _expanded_slab(origin.y, dir.y, bmin.y, bmax.y, ent, lve):
                return false
        return _expanded_slab(origin.z, dir.z, bmin.z, bmax.z, ent, lve)

func _bullet_trace(h: Hull, start: Vector3, direction: Vector3, limit: float) -> BulletWall:
        var num := 0.0
        var num2 := limit
        var i2 := -1
        var i3 := -1
        for j in h.plane_count:
                var o := j * 4
                var nx: float = h.planes[o]
                var ny: float = h.planes[o + 1]
                var nz: float = h.planes[o + 2]
                var dist: float = h.planes[o + 3]
                var num3 := nx * start.x + ny * start.y + nz * start.z - dist
                var num4 := nx * direction.x + ny * direction.y + nz * direction.z
                if absf(num4) < 1e-7:
                        if num3 > 0.0:
                                return null
                        continue
                var num5 := -num3 / num4
                if num4 < 0.0:
                        if num5 > num:
                                num = num5
                                i2 = j
                else:
                        if num5 < num2:
                                num2 = num5
                                i3 = j
                if num > num2:
                        return null
        if num2 <= 0.0 or num >= limit:
                return null
        var hit := BulletWall.new()
        hit.enter_frac = maxf(0.0, num)
        hit.exit_frac = num2
        hit.enter_surface = _surface_at(h, i2)
        hit.exit_surface = _surface_at(h, i3)
        hit.contents = h.contents
        hit.enter_flags = h.plane_flags[i2] if (i2 >= 0 and i2 < h.plane_flags.size()) else 0
        hit.exit_flags = h.plane_flags[i3] if (i3 >= 0 and i3 < h.plane_flags.size()) else 0
        return hit

func _surface_at(h: Hull, i: int) -> int:
        if i >= 0 and i < h.plane_surfaces.size():
                return h.plane_surfaces[i]
        return maxi(h.bullet_surface, 0)

func surface_pen(idx: int) -> float:
        if idx >= 0 and idx < surfaces.size():
                return surfaces[idx].pen
        return 0.5

func surface_dmg(idx: int) -> float:
        if idx >= 0 and idx < surfaces.size():
                return surfaces[idx].dmg
        return 0.25

func surface_kind(idx: int) -> int:
        if idx >= 0 and idx < surfaces.size():
                return surfaces[idx].kind
        return 0

func surface_name(idx: int) -> String:
        if idx >= 0 and idx < surfaces.size():
                return surfaces[idx].name
        return "default"

# ================= 点内容/工具 =================
func point_contents(p: Vector3, contents: int) -> int:
        return _point_contents(0, p, contents)

func _point_contents(nidx: int, p: Vector3, contents: int) -> int:
        if not _expanded_ray(_n_min[nidx], _n_max[nidx], p, Vector3.ZERO, Vector3.ZERO, 1.0):
                return 0
        var d := _n_data
        if d[nidx * 5 + 3] == 0:
                return _point_contents(d[nidx * 5], p, contents) | _point_contents(d[nidx * 5 + 1], p, contents)
        var out := 0
        for i in range(d[nidx * 5 + 2], d[nidx * 5 + 2] + d[nidx * 5 + 3]):
                var h: Hull = hulls[_order[i]]
                if (h.contents & contents) != 0 and _hull_contains(h, p):
                        out |= h.contents
        return out & contents

func _hull_contains(h: Hull, p: Vector3) -> bool:
        for i in h.plane_count:
                if h.plane_dot(i, p) > 0.0:
                        return false
        return true

func clear(feet: Vector3, height: float) -> bool:
        return not sweep(feet, Vector3.ZERO, 0.4064, height, 1).start_solid

func drop(p: Vector3, distance := 10.0) -> Vector3:
        var t := sweep(p + Vector3(0, 0.1, 0), Vector3(0, -distance, 0), 0.0, 0.0, 2)
        if not t.hit:
                return p
        return p + Vector3(0, 0.1 - distance * t.fraction + 0.002, 0)

func ground_player(p: Vector3) -> Vector3:
        var v := p + Vector3(0, 0.65, 0)
        var t := sweep(v, Vector3(0, -3, 0), 0.4064, 1.8288, 1)
        if not t.hit or t.start_solid:
                return p
        return v + Vector3(0, -3.0 * t.fraction + 0.001, 0)

func get_spawn(team: int, ordinal: int) -> Dictionary:
        var count := 0
        for sp in spawns:
                if sp.team == team:
                        count += 1
        ordinal = posmod(ordinal, maxi(1, count))
        for sp in spawns:
                if sp.team != team:
                        continue
                if ordinal == 0:
                        var r: Dictionary = sp.duplicate()
                        r.position = ground_player(sp.position)
                        return r
                ordinal -= 1
        return spawns[0]

func contains(kind: int, p: Vector3) -> bool:
        for v in volumes:
                if v.kind == kind and p.x >= v.bmin.x and p.x <= v.bmax.x and p.z >= v.bmin.z \
                                and p.z <= v.bmax.z and p.y >= v.bmin.y - 0.05 and p.y <= v.bmax.y:
                        return true
        return false

func site(kind: int) -> Vector3:
        for v in volumes:
                if v.kind == kind:
                        return drop((v.bmin + v.bmax) * 0.5)
        return Vector3.ZERO

# ================= 导航 =================
func _build_navigation_index() -> void:
        _nav_order.resize(areas.size())
        for i in areas.size():
                _nav_order[i] = i
                var a := areas[i]
                _nav_center.append(Vector3((a.nw.x + a.se.x) * 0.5, 0.0, (a.nw.z + a.se.z) * 0.5))
                _nav_bmin.append(Vector3(a.nw.x, minf(minf(a.nw.y, a.se.y), minf(a.ne, a.sw)), a.nw.z))
                _nav_bmax.append(Vector3(a.se.x, maxf(maxf(a.nw.y, a.se.y), maxf(a.ne, a.sw)), a.se.z))
        for j in areas.size():
                var links: PackedInt32Array = areas[j].links
                var dist := PackedFloat32Array()
                dist.resize(links.size())
                for k in links.size():
                        if links[k] >= 0:
                                dist[k] = _nav_center[j].distance_to(_nav_center[links[k]])
                _nav_dist.append(dist)
        _pf_cost.resize(areas.size())
        _pf_score.resize(areas.size())
        _pf_h.resize(areas.size())
        _pf_prev.resize(areas.size())
        _pf_heap.resize(areas.size())
        _pf_hpos.resize(areas.size())
        _pf_closed.resize(areas.size())
        if areas.size() > 0:
                _nav_node(0, areas.size())

func _nav_node(start: int, count: int) -> int:
        var idx := _nn_min.size()
        var bmin := Vector3(1e30, 1e30, 1e30)
        var bmax := -bmin
        for i in range(start, start + count):
                bmin = bmin.min(_nav_bmin[_nav_order[i]])
                bmax = bmax.max(_nav_bmax[_nav_order[i]])
        _nn_min.append(bmin)
        _nn_max.append(bmax)
        _nn_data.append_array([0, 0, start, count])
        if count > 6:
                var size := bmax - bmin
                var axis := 0 if size.x >= size.z else 2
                var slice: Array = Array(_nav_order.slice(start, start + count))
                slice.sort_custom(func(a, b) -> bool:
                        return _nav_bmin[a][axis] + _nav_bmax[a][axis] < _nav_bmin[b][axis] + _nav_bmax[b][axis])
                for i in count:
                        _nav_order[start + i] = int(slice[i])
                var mid := count / 2
                var left := _nav_node(start, mid)
                var right := _nav_node(start + mid, count - mid)
                _nn_data[idx * 4] = left
                _nn_data[idx * 4 + 1] = right
                _nn_data[idx * 4 + 3] = 0
        return idx

func _nav_bounds_dist(bmin: Vector3, bmax: Vector3, p: Vector3) -> float:
        var dx := maxf(bmin.x - p.x, maxf(0.0, p.x - bmax.x))
        var dy := maxf(bmin.y - p.y, maxf(0.0, p.y - bmax.y))
        var dz := maxf(bmin.z - p.z, maxf(0.0, p.z - bmax.z))
        return sqrt(dx * dx + dy * dy + dz * dz)

func _find_nearest_area(nidx: int, p: Vector3, found: Array, best: Array) -> void:
        if _nav_bounds_dist(_nn_min[nidx], _nn_max[nidx], p) > best[0] + 1e-6:
                return
        var d := _nn_data
        if d[nidx * 4 + 3] == 0:
                var l := _nav_bounds_dist(_nn_min[d[nidx * 4]], _nn_max[d[nidx * 4]], p)
                var r := _nav_bounds_dist(_nn_min[d[nidx * 4 + 1]], _nn_max[d[nidx * 4 + 1]], p)
                if l <= r:
                        _find_nearest_area(d[nidx * 4], p, found, best)
                        _find_nearest_area(d[nidx * 4 + 1], p, found, best)
                else:
                        _find_nearest_area(d[nidx * 4 + 1], p, found, best)
                        _find_nearest_area(d[nidx * 4], p, found, best)
                return
        for i in range(d[nidx * 4 + 2], d[nidx * 4 + 2] + d[nidx * 4 + 3]):
                var oi := _nav_order[i]
                var len := areas[oi].point(p.x, p.z).distance_to(p)
                if len < best[0] or (len == best[0] and oi < found[0]):
                        best[0] = len
                        found[0] = oi

func nearest(p: Vector3) -> int:
        if areas.is_empty():
                return 0
        var found := [0]
        var best := [1e30]
        _find_nearest_area(0, p, found, best)
        return found[0]

func path(from: Vector3, goal: Vector3) -> PackedVector3Array:
        var out := PackedVector3Array()
        if areas.is_empty():
                return out
        var n := nearest(from)
        var n2 := nearest(goal)
        if n == n2:
                out.append(areas[n2].point(goal.x, goal.z))
                return out
        _pf_count = 0
        for i in areas.size():
                _pf_cost[i] = 1e30
                _pf_prev[i] = -1
                _pf_hpos[i] = -1
                _pf_closed[i] = 0
                _pf_h[i] = _nav_center[i].distance_to(_nav_center[n2])
        _pf_cost[n] = 0.0
        _pf_score[n] = _pf_h[n]
        _pf_push(n)
        while _pf_count > 0:
                var cur := _pf_pop()
                if cur == n2:
                        break
                _pf_closed[cur] = 1
                var links: PackedInt32Array = areas[cur].links
                for j in links.size():
                        var nxt := links[j]
                        if nxt < 0 or _pf_closed[nxt] != 0:
                                continue
                        var cost: float = _pf_cost[cur] + _nav_dist[cur][j] + (3.0 if (areas[nxt].attributes & 2) != 0 else 0.0)
                        if cost < _pf_cost[nxt]:
                                _pf_cost[nxt] = cost
                                _pf_prev[nxt] = cur
                                _pf_score[nxt] = cost + _pf_h[nxt]
                                if _pf_hpos[nxt] < 0:
                                        _pf_push(nxt)
                                else:
                                        _pf_raise(_pf_hpos[nxt])
        if _pf_prev[n2] < 0:
                return out
        var route := PackedInt32Array()
        var walk := n2
        while walk != n:
                route.append(walk)
                walk = _pf_prev[walk]
        route.reverse()
        var prev := n
        for oi in route:
                var a := areas[prev]
                var b := areas[oi]
                var mx := maxf(a.nw.x, b.nw.x)
                var mnx := minf(a.se.x, b.se.x)
                var mz := maxf(a.nw.z, b.nw.z)
                var mnz := minf(a.se.z, b.se.z)
                if mx <= mnx + 0.05 and mz <= mnz + 0.05:
                        var cx := (mx + mnx) * 0.5
                        var cz := (mz + mnz) * 0.5
                        out.append(a.point(cx, cz))
                        out.append(b.point(cx, cz))
                out.append(_nav_center[oi])
                prev = oi
        out.append(areas[n2].point(goal.x, goal.z))
        return out

func _pf_earlier(a: int, b: int) -> bool:
        if _pf_score[a] < _pf_score[b]:
                return true
        return _pf_score[a] == _pf_score[b] and a < b

func _pf_push(node: int) -> void:
        var i := _pf_count
        _pf_count += 1
        _pf_heap[i] = node
        _pf_hpos[node] = i
        _pf_raise(i)

func _pf_raise(i: int) -> void:
        var node := _pf_heap[i]
        while i > 0:
                var parent := (i - 1) / 2
                var other := _pf_heap[parent]
                if not _pf_earlier(node, other):
                        break
                _pf_heap[i] = other
                _pf_hpos[other] = i
                i = parent
        _pf_heap[i] = node
        _pf_hpos[node] = i

func _pf_pop() -> int:
        var top := _pf_heap[0]
        _pf_hpos[top] = -1
        _pf_count -= 1
        if _pf_count == 0:
                return top
        var last := _pf_heap[_pf_count]
        var i := 0
        while i * 2 + 1 < _pf_count:
                var child := i * 2 + 1
                if child + 1 < _pf_count and _pf_earlier(_pf_heap[child + 1], _pf_heap[child]):
                        child += 1
                var other := _pf_heap[child]
                if not _pf_earlier(other, last):
                        break
                _pf_heap[i] = other
                _pf_hpos[other] = i
                i = child
        _pf_heap[i] = last
        _pf_hpos[last] = i
        return top

# ================= 移动辅助 (Steer/ShouldJump) =================
func steer(pos: Vector3, height: float, target_delta: Vector3) -> Vector3:
        var v := target_delta
        v.y = 0.0
        v = v.normalized()
        if v.length() < 0.1:
                return v
        var num := clampf(Vector2(target_delta.x, target_delta.z).length(), 0.6, 1.2)
        var t := sweep(pos, v * num, 0.4064, height, 1)
        if not t.hit or t.normal.y >= 0.7 or t.fraction > 0.75 or should_jump(pos, height, true, v):
                return v
        if not sweep(pos, Vector3(0, 0.4572, 0), 0.4064, height, 1).hit \
                        and not sweep(pos + Vector3(0, 0.4572, 0), v * num, 0.4064, height, 1).hit:
                return v
        var result := v
        var best := -100.0
        for ang in [30.0, -30.0, 60.0, -60.0, 90.0, -90.0, 120.0, -120.0]:
                var s := sin(deg_to_rad(ang))
                var c := cos(deg_to_rad(ang))
                var v2 := Vector3(v.x * c + v.z * s, 0.0, v.z * c - v.x * s)
                var t2 := sweep(pos, v2 * num, 0.4064, height, 1)
                if not t2.start_solid and t2.fraction >= 0.25:
                        var st := pos + v2 * (num * minf(0.95, t2.fraction))
                        var t3 := sweep(st, Vector3(0, -2, 0), 0.4064, height, 1)
                        var val := 2.0 * t3.fraction if t3.hit else 2.0
                        var score := v.dot(v2) * 0.7 + t2.fraction + (minf(val, -target_delta.y) * 1.5 if target_delta.y < -0.5 else 0.0)
                        if score > best:
                                best = score
                                result = v2
        return result

func should_jump(pos: Vector3, height: float, grounded: bool, direction: Vector3) -> bool:
        direction.y = 0.0
        direction = direction.normalized()
        if not grounded or direction.length() < 0.1:
                return false
        if not sweep(pos + Vector3(0, 0.4572, 0), direction * 0.9, 0.4064, height, 1).hit:
                return false
        if sweep(pos, Vector3(0, 1.3, 0), 0.4064, height, 1).hit:
                return false
        return not sweep(pos + Vector3(0, 1.3, 0), direction * 1.2, 0.4064, height, 1).hit
