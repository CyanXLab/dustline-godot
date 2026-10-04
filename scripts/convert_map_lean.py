#!/usr/bin/env python3
"""map.bin → map.dsc 内存精简版: mmap 输入, 磁盘流式输出, 流式 zstd 压缩"""
import struct, os, time, mmap, io
import zstandard as zstd

SRC = "/home/z/my-project/extract/assets/textassets/map.bin"
OUT = "/home/z/my-project/dustline-godot/assets/content/map.dsc"
TMP = "/home/z/my-project/tools/map_body.tmp"
STRIDE = 56

t0 = time.time()
f_in = open(SRC, "rb")
mm = mmap.mmap(f_in.fileno(), 0, access=mmap.ACCESS_READ)
count, = struct.unpack_from("<I", mm, 4)
print(f"记录数 {count}")

# 材质表先扫一遍
mats = {}
off = 8
for i in range(count):
    slen, = struct.unpack_from("<H", mm, off); off += 2
    name = mm[off:off+slen].decode(); off += slen
    if name not in mats:
        mats[name] = len(mats)
    light, vc, ic = struct.unpack_from("<iii", mm, off)
    off += 12 + vc*STRIDE + ic*4
print(f"材质 {len(mats)} 扫描完成 {time.time()-t0:.0f}s")

f_body = open(TMP, "wb")
cctx = zstd.ZstdCompressor(level=19)
stream = cctx.stream_writer(f_body, closefd=False)

off = 8
total_uniq = 0
meta = []
for i in range(count):
    slen, = struct.unpack_from("<H", mm, off); off += 2
    name = mm[off:off+slen].decode(); off += slen
    light, vc, ic = struct.unpack_from("<iii", mm, off); off += 12
    vbase = off
    idbase = vbase + vc*STRIDE
    off = idbase + ic*4
    # 位置范围
    lo = [1e30]*3; hi = [-1e30]*3
    p = vbase
    for v in range(vc):
        x, y, z = struct.unpack_from("<fff", mm, p)
        if x < lo[0]: lo[0] = x
        if y < lo[1]: lo[1] = y
        if z < lo[2]: lo[2] = z
        if x > hi[0]: hi[0] = x
        if y > hi[1]: hi[1] = y
        if z > hi[2]: hi[2] = z
        p += STRIDE
    span = max(max(hi[c]-lo[c] for c in range(3)), 1e-6)
    scale = span / 65535.0
    inv = 1.0/scale
    # 去重 + 量化顶点 → 临时 bytes 列表
    seen = {}
    uniq_data = []
    remap = [0]*vc
    n_uniq = 0
    p = vbase
    for v in range(vc):
        x, y, z = struct.unpack_from("<fff", mm, p)
        nx, ny, nz = struct.unpack_from("<fff", mm, p+12)
        u1, v1 = struct.unpack_from("<ff", mm, p+24)
        u2, v2 = struct.unpack_from("<ff", mm, p+32)
        cr, cg, cb, ca = struct.unpack_from("<ffff", mm, p+40)
        p += STRIDE
        qi = (int((x-lo[0])*inv+0.5) & 0xFFFF,
              int((y-lo[1])*inv+0.5) & 0xFFFF,
              int((z-lo[2])*inv+0.5) & 0xFFFF)
        ax, ay, az = abs(nx)+1e-12, abs(ny)+1e-12, abs(nz)+1e-12
        maj = max(ax, ay, az)
        if ax == maj:
            q0, q1, qm = ny/maj, nz/maj, 0
        elif ay == maj:
            q0, q1, qm = nz/maj, nx/maj, 1
        else:
            q0, q1, qm = nx/maj, ny/maj, 2
        qn = (int((q0*0.5+0.5)*65535) & 0xFFFF, int((q1*0.5+0.5)*65535) & 0xFFFF, qm)
        qc = (int(round(min(max(cr, 0.0), 4.0)/4.0*65535)),
              int(round(min(max(cg, 0.0), 4.0)/4.0*65535)),
              int(round(min(max(cb, 0.0), 4.0)/4.0*65535)),
              int(round(min(max(ca, 0.0), 1.0)*65535)))
        if light >= 0:
            key = struct.pack("<HHHHHHffHHHH", qi[0], qi[1], qi[2], qn[0], qn[1], qn[2], u1, v1, u2, v2, qc[0], qc[1], qc[2], qc[3])
        else:
            key = struct.pack("<HHHHHHffHHHH", qi[0], qi[1], qi[2], qn[0], qn[1], qn[2], u1, v1, 0, 0, qc[0], qc[1], qc[2], qc[3])
        idx = seen.get(key)
        if idx is None:
            idx = seen[key] = n_uniq
            n_uniq += 1
            if light >= 0:
                uniq_data.append(struct.pack("<HHHHHHffHHHH", *qi, *qn, u1, v1, u2, v2, *qc))
            else:
                uniq_data.append(struct.pack("<HHHHHHffHHHH", *qi, *qn, u1, v1, 0.0, 0.0, *qc))
        remap[v] = idx
        if (v & 0xFFFF) == 0:
            seen_bytes = None
    total_uniq += n_uniq
    seen.clear()
    # 索引重映射
    idxs = struct.unpack_from(f"<{ic}I", mm, idbase) if ic else ()
    if n_uniq < 65536:
        idata = struct.pack(f"<{ic}H", *[remap[x] for x in idxs]) if ic else b""
    else:
        idata = struct.pack(f"<{ic}I", *idxs) if ic else b""
    del remap, idxs
    meta.append((mats[name], light, n_uniq, ic, n_uniq < 65536,
                 struct.pack("<fff", *lo) + struct.pack("<f", scale)))
    for chunk in uniq_data:
        stream.write(chunk)
    stream.write(idata)
    del uniq_data, idata
    if i % 400 == 0:
        print(f"  {i}/{count} {time.time()-t0:.0f}s", flush=True)

stream.flush()
zstd.close_stream = True
stream.close()
f_body.close()
body_size = os.path.getsize(TMP)
print(f"体数据 {body_size/1e6:.1f} MB 量化完成 {time.time()-t0:.0f}s")

# 组装最终文件: 头 + 材质表 + 元数据 + zstd(body)
f_body = open(TMP, "rb")
zdec_body = open(OUT, "wb")
# 头部(未压缩) + 压缩体
header = bytearray(b"GDV1")
header += struct.pack("<I", len(mats))
for name, mid in sorted(mats.items(), key=lambda kv: kv[1]):
    b = name.encode()
    header += struct.pack("<H", len(b)) + b
header += struct.pack("<I", len(meta))
for mid, light, nu, ic, u16, origin in meta:
    header += struct.pack("<HhIIB", mid, light, nu, ic, 1 if u16 else 0) + origin
header += struct.pack("<Q", body_size)   # 解压后大小
zdec_body.write(bytes(header))
comp2 = zstd.ZstdCompressor(level=19)
with open(TMP, "rb") as fb:
    comp2.copy_stream(fb, zdec_body)
zdec_body.close()
os.remove(TMP)
print(f"完成: {OUT} {os.path.getsize(OUT)/1e6:.1f} MB  用时 {time.time()-t0:.0f}s")
