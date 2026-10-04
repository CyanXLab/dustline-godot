#!/usr/bin/env python3
"""解析 Dustline TextAsset 的 DSV1 (map) 二进制格式 — v2
格式假设: magic+u32count, 每记录: u16 namelen+name, u32 f0, u32 vcount, u32 icount,
         vcount*56B (pos3+normal3+uv2+extra6 floats), icount*u32 索引
校验目标: 恰好消费整个文件
"""
import struct, sys
from collections import defaultdict

PATH = "/home/z/my-project/extract/assets/textassets/map.bin"
STRIDE = 56  # 14 floats

def main():
    data = open(PATH, "rb").read()
    print(f"文件大小: {len(data):,} bytes")
    assert data[:4] == b"DSV1"
    count, = struct.unpack_from("<I", data, 4)
    print(f"声明记录数={count}")

    off = 8
    mats = defaultdict(lambda: [0, 0, 0])
    total_v = total_i = 0
    f0vals = defaultdict(int)
    bbox = [1e30]*3 + [-1e30]*3
    recno = 0
    try:
        while off < len(data):
            rec_start = off
            slen, = struct.unpack_from("<H", data, off); off += 2
            name = data[off:off+slen].decode("utf-8", "replace"); off += slen
            f0, vc, ic = struct.unpack_from("<III", data, off); off += 12
            f0vals[f0] += 1
            off += vc * STRIDE
            off += ic * 4
            if off > len(data):
                print(f"!! 越界 @{rec_start}: {name} vc={vc} ic={ic} 结束={off}>{len(data)}")
                raise OverflowError
            base = rec_start + 2 + slen + 12
            for v in range(min(vc, 400)):
                x, y, z = struct.unpack_from("<fff", data, base + v*STRIDE)
                bbox[0]=min(bbox[0],x); bbox[1]=min(bbox[1],y); bbox[2]=min(bbox[2],z)
                bbox[3]=max(bbox[3],x); bbox[4]=max(bbox[4],y); bbox[5]=max(bbox[5],z)
            total_v += vc; total_i += ic
            mats[name][0] += 1; mats[name][1] += vc; mats[name][2] += off - rec_start
            recno += 1
            if recno <= 2:
                print(f"[记录{recno}] {name}\n   f0={f0} vc={vc} ic={ic} recbytes={off-rec_start}")
    except OverflowError:
        print(f"解析失败于记录 {recno}")
    print(f"\n成功解析记录: {recno} / 声明 {count}")
    print(f"剩余字节: {len(data)-off}")
    print(f"总顶点: {total_v:,}  总索引: {total_i:,}  三角形: {total_i//3:,}")
    print(f"包围盒: ({bbox[0]:.1f},{bbox[1]:.1f},{bbox[2]:.1f}) ~ ({bbox[3]:.1f},{bbox[4]:.1f},{bbox[5]:.1f})")
    print(f"f0 值分布: {dict(list(f0vals.items())[:8])}")
    print(f"唯一材质: {len(mats)}")
    for name, (c, v, b) in sorted(mats.items(), key=lambda kv: -kv[1][2])[:10]:
        print(f"  {b:>10,} B x{c:<4} v={v:<8} {name[:66]}")

if __name__ == "__main__":
    main()
