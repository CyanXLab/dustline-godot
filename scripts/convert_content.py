#!/usr/bin/env python3
"""Dustline 原版内容 → Godot 优化运行时格式转换器
输出 /home/z/my-project/dustline-godot/assets/content/:
  map.dsc        量化地图几何 (i16 pos + oct16 normal + f32 uv + f32 uv2 + u16 color, 去重, zstd)
  world.dsw      world.bin 原样 zstd (碰撞 hull/出生点/包点/导航area)
  terrain.dst    terrain.bin 原样 zstd (三角碰撞)
  visibility.dsp visibility.bin 原样 zstd (PVS)
  lightmap_0.dlt lightmap_0.bin 原样 zstd (2048x2048 RGBAHalf)
  sky.dsky       sky_original_bc1.bin 原样 zstd
  materials/*.json  map_materials/rig_materials/rig_metadata/sky_manifest/radar/...(JSON 透传)
"""
import struct, os, json, time
import zstandard as zstd

SRC = "/home/z/my-project/extract/assets/textassets"
OUT = "/home/z/my-project/dustline-godot/assets/content"
os.makedirs(OUT, exist_ok=True)

ZC = zstd.ZstdCompressor(level=19, write_content_size=True, write_checksum=True)

def zsave(name, data):
    c = ZC.compress(data)
    open(f"{OUT}/{name}", "wb").write(c)
    print(f"  {name}: {len(data)/1e6:.1f} MB → {len(c)/1e6:.1f} MB")
    return c

def convert_map():
    print("== map.bin → map.dsc ==")
    t0 = time.time()
    data = open(f"{SRC}/map.bin", "rb").read()
    count, = struct.unpack_from("<I", data, 4)
    STRIDE = 56
    off = 8
    mats = {}
    recs_meta = []
    body = bytearray()
    body_off = 0
    for i in range(count):
        slen, = struct.unpack_from("<H", data, off); off += 2
        name = data[off:off+slen].decode(); off += slen
        light, vc, ic = struct.unpack_from("<iii", data, off); off += 12
        vbase = off
        idbase = vbase + vc*STRIDE
        off = idbase + ic*4
        if name not in mats:
            mats[name] = len(mats)
        # 顶点范围(位置)
        lo = [1e30]*3; hi = [-1e30]*3
        p = vbase
        for v in range(vc):
            x, y, z = struct.unpack_from("<fff", data, p); p += STRIDE
            if x < lo[0]: lo[0] = x
            if y < lo[1]: lo[1] = y
            if z < lo[2]: lo[2] = z
            if x > hi[0]: hi[0] = x
            if y > hi[1]: hi[1] = y
            if z > hi[2]: hi[2] = z
        span = max(max(hi[c]-lo[c] for c in range(3)), 1e-6)
        scale = span / 65535.0
        inv = 1.0/scale
        # 去重
        seen = {}
        remap = [0]*vc
        qverts = bytearray()
        n_uniq = 0
        p = vbase
        for v in range(vc):
            x, y, z = struct.unpack_from("<fff", data, p)
            nx, ny, nz = struct.unpack_from("<fff", data, p+12)
            u1, v1 = struct.unpack_from("<ff", data, p+24)
            u2, v2 = struct.unpack_from("<ff", data, p+32)
            cr, cg, cb, ca = struct.unpack_from("<ffff", data, p+40)
            p += STRIDE
            qi = (int((x-lo[0])*inv+0.5) & 0xFFFF,
                  int((y-lo[1])*inv+0.5) & 0xFFFF,
                  int((z-lo[2])*inv+0.5) & 0xFFFF)
            # octahedral 16bit: 存符号+量化
            ax, ay, az = abs(nx)+1e-12, abs(ny)+1e-12, abs(nz)+1e-12
            maj = max(ax, ay, az)
            if ax == maj:
                q = (ny/maj, nz/maj); mode = 0
            elif ay == maj:
                q = (nz/maj, nx/maj); mode = 1
            else:
                q = (nx/maj, ny/maj); mode = 2
            qn = (int((q[0]*0.5+0.5)*65535) & 0xFFFF,
                  int((q[1]*0.5+0.5)*65535) & 0xFFFF, mode)
            qc = (int(round(min(max(cr, 0.0), 4.0)/4.0*65535)),
                  int(round(min(max(cg, 0.0), 4.0)/4.0*65535)),
                  int(round(min(max(cb, 0.0), 4.0)/4.0*65535)),
                  int(round(min(max(ca, 0.0), 1.0)*65535)))
            key = (qi, qn, (u1, v1), (u2, v2) if light >= 0 else None, qc)
            idx = seen.get(key)
            if idx is None:
                idx = seen[key] = n_uniq
                n_uniq += 1
                qverts += struct.pack("<HHHHHH", *qi, *qn)
                qverts += struct.pack("<ff", u1, v1)
                if light >= 0:
                    qverts += struct.pack("<ff", u2, v2)
                qverts += struct.pack("<HHHH", *qc)
            remap[v] = idx
        # 索引
        idxs = struct.unpack(f"<{ic}I", data[idbase:off]) if ic else ()
        u16 = n_uniq < 65536
        idata = bytearray()
        if u16:
            idata += struct.pack(f"<{ic}H", *[remap[x] & 0xFFFF for x in idxs])
        else:
            idata += struct.pack(f"<{ic}I", *[remap[x] for x in idxs])
        nb = bytes(qverts)
        recs_meta.append((mats[name], light, n_uniq, ic, u16,
                          struct.pack("<fff", *lo) + struct.pack("<f", scale)))
        body += nb + bytes(idata)
    # 组装
    out = bytearray(b"GDV1")
    out += struct.pack("<I", len(mats))
    for name, mid in sorted(mats.items(), key=lambda kv: kv[1]):
        b = name.encode()
        out += struct.pack("<H", len(b)) + b
    out += struct.pack("<I", len(recs_meta))
    for mid, light, nu, ic, u16, origin in recs_meta:
        out += struct.pack("<HhII B", mid, light, nu, ic, 1 if u16 else 0) + origin
    body_start = len(out)
    out += body
    zsave("map.dsc", bytes(out))
    print(f"  记录 {len(recs_meta)} 材质 {len(mats)} 顶点去重后 {sum(m[2] for m in recs_meta)}")
    print(f"  用时 {time.time()-t0:.0f}s")

def pass_z(name, src):
    print(f"== {src} → {name} ==")
    zsave(name, open(f"{SRC}/{src}", "rb").read())

def pass_json(name):
    src = name
    print(f"== {src} (JSON 透传) ==")
    data = open(f"{SRC}/{src}", "rb").read()
    open(f"{OUT}/{src.replace('.bin', '.json')}", "wb").write(data)
    print(f"  {len(data)/1e3:.0f} KB")

if __name__ == "__main__":
    which = sys_arg = None
    import sys
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    if which in ("all", "map"):
        convert_map()
    if which in ("all", "bin"):
        pass_z("world.dsw", "world.bin")
        pass_z("terrain.dst", "terrain.bin")
        pass_z("visibility.dsp", "visibility.bin")
        pass_z("lightmap_0.dlt", "lightmap_0.bin")
        pass_z("sky.dsky", "sky_original_bc1.bin")
    if which in ("all", "json"):
        for j in ["map_materials", "rig_materials", "rig_metadata", "sky_manifest", "radar",
                  "definition_1", "sound_events", "animation_events", "player_physics",
                  "player_aim", "player_locomotion", "rig_manifest"]:
            pass_json(j + ".bin")
    print("完成")
