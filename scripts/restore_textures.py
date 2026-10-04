#!/usr/bin/env python3
"""从 .godot/imported 陈旧缓存恢复全部被引用纹理 → assets/textures/*.ctex
背景: 上一轮"优化"误删了 assets/textures/ 下的 PNG 源文件, 但 Godot 导入缓存
(.godot/imported/<hash>.png-<p>.s3tc.ctex) 仍保留全部已导入纹理 (S3TC 桌面格式)。
ctex 是标准 CompressedTexture2D 资源, Godot 4 可直接 load() 无需再导入。
"""
import json, os, shutil, sys

PROJ = '/home/z/my-project/dustline-godot'
IMP = os.path.join(PROJ, '.godot', 'imported')
OUT = os.path.join(PROJ, 'assets', 'textures')

def refs_from(path):
    d = json.load(open(path))
    refs = set()
    for m in d.get('materials', []):
        for k in ('base', 'normal', 'second'):
            h = m.get(k, '')
            if h:
                refs.add(h)
    return refs

def main():
    refs = refs_from(os.path.join(PROJ, 'assets/content/map_materials.json'))
    refs |= refs_from(os.path.join(PROJ, 'assets/content/rig_materials.json'))
    refs.add('cc_dust2')  # LUT (代码引用)
    print('需要恢复纹理:', len(refs))

    by_base = {}
    for f in os.listdir(IMP):
        for ext in ('.png-', '.jpg-'):
            if ext in f and f.endswith('.ctex'):
                by_base.setdefault(f.split(ext)[0], []).append(f)
                break

    os.makedirs(OUT, exist_ok=True)
    restored, missing, total = 0, [], 0
    for h in sorted(refs):
        cands = by_base.get(h)
        if not cands:
            missing.append(h)
            continue
        # 优先 s3tc (Windows 桌面), 其次任意
        pick = ([c for c in cands if 's3tc' in c] or cands)[0]
        src = os.path.join(IMP, pick)
        dst = os.path.join(OUT, h + '.ctex')
        shutil.copyfile(src, dst)
        restored += 1
        total += os.path.getsize(src)
    print('恢复: %d  缺失: %d  体积: %.1f MB' % (restored, len(missing), total / 1048576))
    if missing:
        print('缺失清单:', missing[:20])
        sys.exit(1)
    print('OK →', OUT)

if __name__ == '__main__':
    main()
