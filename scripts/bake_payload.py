#!/usr/bin/env python3
"""map.bin → Godot 烘焙载荷 (numpy 向量化, 全量顶点, 与原版几何完全一致)
输出 dustline-godot/assets/content/map_bake.gvb + map_bake.json
按 (材质, 光照) 合并 chunk; 顶点不做去重 (保留原始法线/UV 全部细节)
"""
import struct, json, time, os
import numpy as np

SRC = "/home/z/my-project/extract/assets/textassets/map.bin"
OUTG = "/home/z/my-project/dustline-godot/assets/content/map_bake.gvb"
OUTJ = "/home/z/my-project/dustline-godot/assets/content/map_bake.json"

t0 = time.time()
raw = open(SRC, "rb").read(8)
count, = struct.unpack_from("<I", raw, 4)
print(f"记录 {count}", flush=True)

# 逐记录扫头
recs = []
mats = {}
off = 8
with open(SRC, "rb") as f:
    data = f.read()
off = 8
for i in range(count):
    slen, = struct.unpack_from("<H", data, off); off += 2
    name = data[off:off+slen].decode(); off += slen
    light, vc, ic = struct.unpack_from("<iii", data, off); off += 12
    mats.setdefault(name, len(mats))
    recs.append((name, light, vc, ic, off))
    off += vc*56 + ic*4
del data
print(f"扫描 {time.time()-t0:.0f}s 材质 {len(mats)}", flush=True)

total_v = sum(r[2] for r in recs)
total_i = sum(r[3] for r in recs)
print(f"顶点 {total_v:,} 索引 {total_i:,}")

# --- 按组收集 (材质, 光照): 顶点直接拼接, 索引加基址偏移 ---
groups = {}
for name, light, vc, ic, vbase in recs:
    groups.setdefault((mats[name], light), []).append((vc, ic, vbase))

def variant_blob(t, payload):
    return struct.pack("<I", t) + payload

def v3a(a):
    return variant_blob(36, struct.pack("<i", len(a)) + np.ascontiguousarray(a, "<f4").tobytes())
def v2a(a):
    return variant_blob(35, struct.pack("<i", len(a)) + np.ascontiguousarray(a, "<f4").tobytes())
def ia(a):
    return variant_blob(30, struct.pack("<i", len(a)) + np.ascontiguousarray(a, "<i4").tobytes())
def ca(a):
    return variant_blob(37, struct.pack("<i", len(a)) + np.ascontiguousarray(a, "<f4").tobytes())

blobs = bytearray()
entries = []
mesh_list = []
mid_to_name = {v: k for k, v in mats.items()}

with open(SRC, "rb") as f:
    mm = None
    for gi, ((mid, light), lst) in enumerate(sorted(groups.items(), key=lambda kv: (kv[0][1], kv[0][0]))):
        tv = sum(v for v, _, _ in lst)
        ti = sum(i for _, i, _ in lst)
        P = np.empty((tv, 3), "<f4"); N = np.empty((tv, 3), "<f4")
        U = np.empty((tv, 2), "<f4"); C = np.empty((tv, 4), "<f4")
        U2 = np.empty((tv, 2), "<f4") if light >= 0 else None
        I = np.empty(ti, "<u4")
        vp = ip = 0
        for vc, ic, vbase in lst:
            va = np.frombuffer(f.read(0), dtype="<f4")  # noop placeholder
            f.seek(vbase)
            arr = np.frombuffer(f.read(vc*56), dtype="<f4").reshape(vc, 14)
            P[vp:vp+vc] = arr[:, 0:3]
            N[vp:vp+vc] = arr[:, 3:6]
            U[vp:vp+vc] = arr[:, 6:8]
            if light >= 0:
                U2[vp:vp+vc] = arr[:, 8:10]
            C[vp:vp+vc] = arr[:, 10:14]
            if ic:
                f.seek(vbase + vc*56)
                I[ip:ip+ic] = np.frombuffer(f.read(ic*4), dtype="<u4") + vp
            vp += vc; ip += ic
        # 法线归一化 + 非法值修复
        ln = np.linalg.norm(N, axis=1, keepdims=True)
        bad = (~np.isfinite(ln)) | (ln < 0.5) | (ln > 1.5)
        bad = np.reshape(bad, -1)
        if bad.any():
            N[bad] = np.array([0, 1, 0], "<f4")
            ln = np.linalg.norm(N, axis=1, keepdims=True)
            print(f"  [{gi}] 修复非法法线 {int(bad.sum())}", flush=True)
        N /= np.maximum(ln, 1e-9)
        C[:, :3] = np.clip(C[:, :3], 0.0, 4.0)
        C[:, 3] = np.clip(C[:, 3], 0.0, 1.0)
        # AABB
        mn, mx = P.min(axis=0), P.max(axis=0)
        mesh_name = f"m{gi:03d}"
        mesh_list.append({"mesh": mesh_name, "material": mid_to_name[mid],
                          "light": int(light), "verts": int(tv), "tris": int(ti)//3,
                          "aabb_min": [float(x) for x in mn], "aabb_max": [float(x) for x in mx]})
        secs = [("pos", v3a(P)), ("nrm", v3a(N)), ("uv", v2a(U)), ("col", ca(C))]
        if light >= 0:
            secs.append(("uv2", v2a(U2)))
        secs.append(("idx", ia(I)))
        for sname, blob in secs:
            entries.append((f"{mesh_name}_{sname}", len(blobs), len(blob)))
            blobs += blob
        del P, N, U, U2, C, I
        print(f"  网格 {gi} {mesh_name} {mid_to_name[mid][:40]} light={light} v={tv} {time.time()-t0:.0f}s", flush=True)

hdr_end = 4 + 4 + 8 + sum(1 + len(n) + 16 for n, _, _ in entries)
out = bytearray(b"GVV1")
out += struct.pack("<I", len(entries)) + struct.pack("<Q", hdr_end)
for n, o, sz in entries:
    nb = n.encode()
    out += struct.pack("<B", len(nb)) + nb + struct.pack("<QQ", o, sz)
out += blobs
open(OUTG, "wb").write(bytes(out))
json.dump({"meshes": mesh_list, "materials_order": [k for k, _ in sorted(mats.items(), key=lambda kv: kv[1])]},
          open(OUTJ, "w"))
print(f"完成: {os.path.getsize(OUTG)/1e6:.1f} MB, 网格 {len(mesh_list)}, 用时 {time.time()-t0:.0f}s")
