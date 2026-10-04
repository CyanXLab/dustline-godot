#!/usr/bin/env python3
"""分析恢复出的 ctex 纹理: 格式直方图 + BC3(DXT5)→BC1(DXT1) 可瘦身空间
ctex v3 头: "GST2" + u32 version + u32 width + u32 height + u32 flags
之后是若干 (u32 data_format, u32 width, u32 height, u32 blockfmt?) 块描述...
用已知值反推: 对 2048x1024 等文件按大小推断 DXT1(0.5B/px) vs DXT5(1B/px) + mips(+33%)
"""
import os, struct, sys

TEX = '/home/z/my-project/dustline-godot/assets/textures'

def parse_header(path):
    with open(path, 'rb') as f:
        head = f.read(64)
    if head[:4] != b'GST2':
        return None
    ver, w, h, flags = struct.unpack_from('<IIII', head, 4)
    return ver, w, h, flags, head

def main():
    files = sorted(os.listdir(TEX))
    total = 0
    buckets = {}
    suspicious = []
    for fn in files:
        p = os.path.join(TEX, fn)
        sz = os.path.getsize(p)
        total += sz
        h = parse_header(p)
        if h is None:
            suspicious.append(fn)
            continue
        ver, w, h_, flags, head = h
        # 每像素字节数估算 (含 mip ~1.33)
        bpp = sz * 1.0 / (w * h_)
        if bpp < 0.75:      kind = 'DXT1-ish (0.5B/px)'
        elif bpp < 1.1:     kind = 'DXT5/BC5-ish (1B/px)'
        elif bpp < 1.6:     kind = 'lossless-comp'
        else:               kind = 'uncompressed?'
        dim = '%dx%d' % (w, h_)
        key = (dim, kind)
        b = buckets.setdefault(key, [0, 0])
        b[0] += 1
        b[1] += sz
    print('文件数: %d  总计: %.1f MB' % (len(files), total / 1048576))
    for (dim, kind), (n, sz) in sorted(buckets.items(), key=lambda kv: -kv[1][1]):
        print('%-10s %-22s n=%-4d %8.1f MB' % (dim, kind, n, sz / 1048576))
    if suspicious:
        print('非GST2文件:', suspicious[:5])
    # hexdump 一个大文件头 40 字节
    for fn in files:
        p = os.path.join(TEX, fn)
        if os.path.getsize(p) > 3_000_000:
            head = parse_header(p)
            print('样例:', fn, head[:4], head[4][:40].hex())
            break

if __name__ == '__main__':
    main()
