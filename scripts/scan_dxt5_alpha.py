#!/usr/bin/env python3
"""扫描 DXT5 纹理 alpha: 完全不透明 → /tmp/dxt5_opaque.txt (可转 DXT1)
DXT5 每块 16B: [a0,a1,alpha-idx6B][color 8B]。a0==255 且 a1==255 → 块全不透明。
法线贴图 (Unity DXT5nm, alpha 存 X) 必有 a<255 → 自动排除, 绝不转换。
"""
import json, os
import numpy as np

CLS = '/tmp/tex_class.json'
TEX = '/home/z/my-project/dustline-godot/assets/textures'

def data_size(w, h):
    total, mw, mh = 0, w, h
    while True:
        total += max(1, mw) * max(1, mh)
        if mw == 1 and mh == 1:
            break
        mw = max(1, mw // 2); mh = max(1, mh // 2)
    return total  # DXT5 = 1 B/px

def main():
    d = json.load(open(CLS))
    opaque, has_alpha, bad = [], [], []
    for f, v in d.items():
        if 'err' in v or v['fmt'] != 19:
            continue
        p = os.path.join(TEX, f)
        sz = os.path.getsize(p)
        off = sz - data_size(v['w'], v['h'])
        if off <= 0:
            bad.append(f); continue
        raw = np.fromfile(p, dtype=np.uint8, offset=off)
        n = (len(raw) // 16) * 16
        blocks = raw[:n].reshape(-1, 16)
        mn = int(blocks[:, 0].min()); mx = int(blocks[:, 1].max())
        if mn == 255 and mx == 255:
            opaque.append(f)
        else:
            has_alpha.append((f, mn, mx))
    op_mb = sum(os.path.getsize(os.path.join(TEX, f)) for f in opaque) / 1048576
    print('DXT5 总数: %d  完全不透明: %d (%.1fMB)  有alpha: %d  异常: %d'
          % (len(opaque) + len(has_alpha) + len(bad), len(opaque), op_mb, len(has_alpha), len(bad)))
    print('alpha样例(应为法线/遮罩):', has_alpha[:5])
    print('透明占比: %.1fMB 可省约 %.1fMB'
          % (op_mb, op_mb / 2))
    open('/tmp/dxt5_opaque.txt', 'w').write('\n'.join(opaque))

if __name__ == '__main__':
    main()
