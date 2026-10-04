#!/usr/bin/env python3
"""DSR2 骨架文件 → Godot 烘焙载荷 (.gvb 每骨架一个 + rigs_bake.json 清单)
格式 (SourceRig.Load 反编译对照):
  magic u32 (DSR1=827478852 | DSR2=844256068)
  boneCount u32; per bone: name u16+str, parent i32, pos 3f, rot quat 4f
  partCount u32; per part: [DSR2: partName u16+str], material u16+str,
              vertCount i32, indexCount i32, verts vc*8f(pos3 nrm3 uv2),
              boneIdx vc*4 u16, weights vc*4 f32, idx ic*u32
  clipCount u32; per clip: name u16+str, fps f32, frames i32, loop u8, delta u8,
              bones*frames*(pos3+quat4) f32
"""
import struct, json, os, sys, time
import numpy as np

SRC = "/home/z/my-project/extract/assets/textassets"
OUT = "/home/z/my-project/dustline-godot/assets/content/rig_payload"
MANIFEST_OUT = "/home/z/my-project/dustline-godot/assets/content/rigs_bake.json"
os.makedirs(OUT, exist_ok=True)

def read_str(buf, off):
    n, = struct.unpack_from("<H", buf, off)
    off += 2
    return buf[off:off+n].decode("utf-8", "replace"), off + n

def convert(name):
    path = f"{SRC}/{name}.bin"
    if not os.path.exists(path):
        return None
    buf = open(path, "rb").read()
    magic, = struct.unpack_from("<I", buf, 0)
    if magic not in (827478852, 844256068):
        return None
    is_dsr2 = magic == 844256068
    off = 4
    bone_count, = struct.unpack_from("<I", buf, off); off += 4
    bones = []
    for i in range(bone_count):
        bn, off = read_str(buf, off)
        parent, = struct.unpack_from("<i", buf, off); off += 4
        pos = struct.unpack_from("<3f", buf, off); off += 12
        rot = struct.unpack_from("<4f", buf, off); off += 16
        bones.append({"name": bn, "parent": parent, "pos": pos, "rot": rot})
    part_count, = struct.unpack_from("<I", buf, off); off += 4
    parts = []
    sections = []
    blobs = bytearray()
    for j in range(part_count):
        if is_dsr2:
            pname, off = read_str(buf, off)
        else:
            pname = name
        material, off = read_str(buf, off)
        vc, ic = struct.unpack_from("<ii", buf, off); off += 8
        vdata = np.frombuffer(buf, dtype="<f4", count=vc*8, offset=off).reshape(vc, 8); off += vc*32
        bidx = np.frombuffer(buf, dtype="<u2", count=vc*4, offset=off).reshape(vc, 4); off += vc*8
        bw = np.frombuffer(buf, dtype="<f4", count=vc*4, offset=off).reshape(vc, 4); off += vc*16
        idx = np.frombuffer(buf, dtype="<u4", count=ic, offset=off); off += ic*4
        pid = f"p{j}"
        for suffix, arr, tag in [
            ("pos", vdata[:, 0:3], 36), ("nrm", vdata[:, 3:6], 36),
            ("uv", vdata[:, 6:8], 35)]:
            blob = struct.pack("<I", tag) + struct.pack("<i", len(arr)) + np.ascontiguousarray(arr, "<f4").tobytes()
            sections.append((f"{pid}_{suffix}", len(blobs), len(blob)))
            blobs += blob
        # 骨骼索引/权重: 打包为 float32 数组节 (避免额外类型)
        blob = struct.pack("<I", 32) + struct.pack("<i", vc*4) + np.ascontiguousarray(bidx.astype("<f4")).tobytes()
        sections.append((f"{pid}_bidx", len(blobs), len(blob)))
        blobs += blob
        blob = struct.pack("<I", 32) + struct.pack("<i", vc*4) + np.ascontiguousarray(bw, "<f4").tobytes()
        sections.append((f"{pid}_bw", len(blobs), len(blob)))
        blobs += blob
        blob = struct.pack("<I", 30) + struct.pack("<i", ic) + np.ascontiguousarray(idx, "<i4").tobytes()
        sections.append((f"{pid}_idx", len(blobs), len(blob)))
        blobs += blob
        parts.append({"pid": pid, "part": pname, "material": material, "verts": vc, "tris": ic // 3})
    clip_count, = struct.unpack_from("<I", buf, off); off += 4
    clips = []
    for k in range(clip_count):
        cname, off = read_str(buf, off)
        fps, frames = struct.unpack_from("<fi", buf, off); off += 8
        loop, delta = struct.unpack_from("<BB", buf, off); off += 2
        n = bone_count * frames
        arr = np.frombuffer(buf, dtype="<f4", count=n*7, offset=off).reshape(n, 7); off += n*28
        # 两节: pos (n×3) 和 quat (n×4)
        blob = struct.pack("<I", 36) + struct.pack("<i", n) + np.ascontiguousarray(arr[:, 0:3], "<f4").tobytes()
        sections.append((f"c{k}_pos", len(blobs), len(blob)))
        blobs += blob
        blob = struct.pack("<I", 32) + struct.pack("<i", n*4) + np.ascontiguousarray(arr[:, 3:7], "<f4").tobytes()
        sections.append((f"c{k}_quat", len(blobs), len(blob)))
        blobs += blob
        clips.append({"cid": f"c{k}", "name": cname, "fps": fps, "frames": frames,
                      "loop": bool(loop), "delta": bool(delta)})
    if off != len(buf):
        print(f"  警告 {name}: 剩余 {len(buf)-off} 字节未解析")
    # 写 .gvb
    hdr_end = 4 + 4 + 8 + sum(1 + len(n2) + 16 for n2, _, _ in sections)
    out = bytearray(b"GVV1")
    out += struct.pack("<I", len(sections)) + struct.pack("<Q", hdr_end)
    for n2, o, sz in sections:
        nb = n2.encode()
        out += struct.pack("<B", len(nb)) + nb + struct.pack("<QQ", o, sz)
    out += blobs
    open(f"{OUT}/{name}.gvb", "wb").write(bytes(out))
    return {"name": name, "bones": bones, "parts": parts, "clips": clips,
            "sections": len(sections), "payload_size": len(blobs)}

if __name__ == "__main__":
    t0 = time.time()
    names = sorted(f[:-4] for f in os.listdir(SRC)
                   if f.endswith(".bin") and (f[:-4].endswith(("_view", "_world", "_dropped", "_arms"))
                                              or f[:-4] in ("t_leet", "ct_idf")))
    print("骨架文件:", len(names))
    manifest = []
    skipped = 0
    for n in names:
        r = convert(n)
        if r is None:
            skipped += 1
            continue
        manifest.append({k: r[k] for k in ("name", "parts", "clips", "payload_size")})
        # 骨骼数据进 manifest (bake 用)
        manifest[-1]["bones"] = r["bones"]
    json.dump(manifest, open(MANIFEST_OUT, "w"))
    total = sum(m["payload_size"] for m in manifest)
    print(f"转换 {len(manifest)} 跳过 {skipped} 载荷合计 {total/1e6:.1f} MB 用时 {time.time()-t0:.0f}s")
