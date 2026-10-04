#!/usr/bin/env python3
"""测量 map.bin 各种优化方案的实际压缩率 (前 N 条记录采样)"""
import struct, zstandard as zstd
import io

PATH = "/home/z/my-project/extract/assets/textassets/map.bin"
STRIDE = 56
SAMPLE_RECORDS = 600  # 采样量

data = open(PATH, "rb").read()
count, = struct.unpack_from("<I", data, 4)

def compress(buf, level=19):
    c = zstd.ZstdCompressor(level=level, write_content_size=False, write_checksum=False)
    return c.compress(buf)

# 解析采样记录
recs = []
off = 8
for i in range(SAMPLE_RECORDS):
    slen, = struct.unpack_from("<H", data, off); off += 2
    name = data[off:off+slen].decode(); off += slen
    light, vc, ic = struct.unpack_from("<iii", data, off); off += 12
    vdata = data[off:off+vc*STRIDE]; off += vc*STRIDE
    idata = data[off:off+ic*4]; off += ic*4
    recs.append((name, light, vc, ic, vdata, idata))
raw_total = off - 8
print(f"采样 {len(recs)} 记录 原始 {raw_total/1e6:.1f} MB (全文件比例 {raw_total/(len(data)-8)*100:.0f}%)")

# 方案V1: 直接zstd
v1 = compress(data[8:off])
print(f"V1 原始zstd: {len(v1)/1e6:.1f} MB ({len(v1)/raw_total*100:.0f}%)")

# 方案V2: 去重 + f32 重排 + zstd
import sys
sys.path.insert(0, '/home/z/my-project/scripts')

def dedup_emit(recs, quant_pos=True, emit_f32=True):
    """去重后重排顶点. quant_pos: 用 i16 量化做去重键"""
    out = bytearray()
    out += b"DSV2" + struct.pack("<I", len(recs))
    mat_ids = {}
    for (name, light, vc, ic, vdata, idata) in recs:
        if name not in mat_ids:
            mat_ids[name] = len(mat_ids)
    out += struct.pack("<I", len(mat_ids))
    for name in mat_ids:
        b = name.encode(); out += struct.pack("<H", len(b)) + b
    for (name, light, vc, ic, vdata, idata) in recs:
        # 解析顶点
        verts = []
        for v in range(vc):
            p = v*STRIDE
            pos = struct.unpack_from("<fff", vdata, p)
            nrm = struct.unpack_from("<fff", vdata, p+12)
            uv = struct.unpack_from("<ff", vdata, p+24)
            uv2 = struct.unpack_from("<ff", vdata, p+32)
            col = struct.unpack_from("<ffff", vdata, p+40)
            verts.append((pos, nrm, uv, uv2, col))
        # 量化键去重
        lo = [min(v[0][c] for v in verts) for c in range(3)]
        span = max(max(v[0][c] for v in verts)-lo[c] for c in range(3)) or 1.0
        scale = span / 65000.0
        seen = {}
        remap = [0]*vc
        for v, t in enumerate(verts):
            qi = tuple(int((t[0][c]-lo[c])/scale+0.5) for c in range(3))
            qn = tuple(int(round((t[1][c]*0.5+0.5)*65535)) for c in range(3))
            qu = t[2]; qu2 = t[3]
            qc = tuple(int(round(min(max(t[4][c],0),65535/16384)*16384)) for c in range(4))
            key = (qi, qn, qu, qu2, qc)
            if key in seen:
                remap[v] = seen[key]
            else:
                remap[v] = seen[key] = len(seen)
        uniq = [None]*len(seen)
        for v, t in enumerate(verts):
            if remap[v] < len(uniq) and uniq[remap[v]] is None:
                uniq[remap[v]] = t
        # 发射
        out += struct.pack("<HiI I", mat_ids[name], light, len(seen), ic)
        out += struct.pack("<fff", *lo) + struct.pack("<f", scale)
        if emit_f32:
            for t in uniq:
                out += struct.pack("<fff", *t[0])
                out += struct.pack("<fff", *t[1])
                out += struct.pack("<ff", *t[2])
                out += struct.pack("<ff", *t[3])
                out += struct.pack("<ffff", *t[4])
        else:
            for t in uniq:
                qi = tuple(int((t[0][c]-lo[c])/scale+0.5) for c in range(3))
                out += struct.pack("<HHH", *[min(max(x,0),65535) for x in qi])
                nx, ny, nz = t[1]
                # octahedral
                ax, ay, az = abs(nx), abs(ny), abs(nz)
                maj = max(ax, ay, az) or 1.0
                if ax == maj:
                    octv = (ny/maj*0.5+0.5)*65535, (nz/maj*0.5+0.5)*65535, 0
                elif ay == maj:
                    octv = (nz/maj*0.5+0.5)*65535, (nx/maj*0.5+0.5)*65535, 1
                else:
                    octv = (nx/maj*0.5+0.5)*65535, (ny/maj*0.5+0.5)*65535, 2
                octv = tuple(min(65535, max(0, int(x))) for x in octv)
                out += struct.pack("<HHB", *octv)
                out += struct.pack("<ff", *t[2])
                if light >= 0: out += struct.pack("<ff", *t[3])
                out += struct.pack("<HHHH", *[min(65535, x) for x in (
                    int(round(min(max(t[4][0],0),4)/4*65535)), int(round(min(max(t[4][1],0),4)/4*65535)),
                    int(round(min(max(t[4][2],0),4)/4*65535)), int(round(min(max(t[4][3],0),1)*65535)))])
        # 索引重映射
        idx = struct.unpack(f"<{ic}I", idata) if ic else ()
        if len(seen) < 65536:
            out += struct.pack(f"<{ic}H", *[remap[x] for x in idx])
        else:
            out += struct.pack(f"<{ic}I", *[remap[x] for x in idx])
    return bytes(out)

v2 = dedup_emit(recs, emit_f32=True)
c2 = compress(v2)
print(f"V2 去重+f32+zstd: {len(v2)/1e6:.1f} → {len(c2)/1e6:.1f} MB ({len(c2)/raw_total*100:.0f}%)")

v3 = dedup_emit(recs, emit_f32=False)
c3 = compress(v3)
print(f"V3 量化+zstd:     {len(v3)/1e6:.1f} → {len(c3)/1e6:.1f} MB ({len(c3)/raw_total*100:.0f}%)")
nv = sum(r[2] for r in recs)
nu = 0
print(f"(采样顶点 {nv}, 压缩后顶点比例见日志)")
