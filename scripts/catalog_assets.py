#!/usr/bin/env python3
"""清点 Dustline Unity 构建中的所有资产：类型/名称/容器路径/大小"""
import UnityPy, os, json, sys
from collections import defaultdict

DATA = "/home/z/my-project/dustline/Dustline_Data"
OUT = "/home/z/my-project/extract/catalog.json"
os.makedirs("/home/z/my-project/extract", exist_ok=True)

files = []
for f in sorted(os.listdir(DATA)):
    if f.endswith((".assets", ".resource", ".assets.resS", ".bundle")) or f.startswith(("level", "sharedassets", "globalgamemanagers")):
        files.append(os.path.join(DATA, f))
# resources.resource / .resS 是数据文件，由 UnityPy 自动跟随，不需要单独 load
files = [f for f in files if not f.endswith((".resS", ".resource"))]
print("加载文件:", [os.path.basename(f) for f in files])

catalog = []
type_count = defaultdict(int)
seen = set()

for fp in files:
    env = UnityPy.load(fp)
    for obj in env.objects:
        try:
            td = obj.type.name
        except Exception:
            continue
        name, container = "", ""
        size = 0
        try:
            if td == "GameObject":
                d = obj.read()
                name = d.m_Name
            elif td in ("Texture2D",):
                d = obj.read()
                name = d.m_Name; size = d.m_Width * d.m_Height * 4
            elif td == "AudioClip":
                d = obj.read(); name = d.m_Name
            elif td == "Mesh":
                d = obj.read(); name = d.m_Name
            elif td == "Material":
                d = obj.read(); name = d.m_Name
            elif td == "Sprite":
                d = obj.read(); name = d.m_Name
            elif td == "TextAsset":
                d = obj.read(); name = d.m_Name; size = len(d.m_Script) if d.m_Script else 0
            elif td == "MonoBehaviour":
                d = obj.read()
                name = d.m_Name
            elif td == "Shader":
                d = obj.read(); name = d.m_Name
            elif td == "AnimationClip":
                d = obj.read(); name = d.m_Name
            elif td == "GameObject":
                pass
            container = ""
            try:
                container = obj.container or ""
            except Exception:
                pass
        except Exception as e:
            name = f"<err {type(e).__name__}>"
        key = (td, name, container, obj.assets_file.name if hasattr(obj, 'assets_file') else "")
        if key in seen:
            continue
        seen.add(key)
        type_count[td] += 1
        catalog.append({"file": os.path.basename(fp), "type": td, "name": name, "container": container, "size": size})

with open(OUT, "w", encoding="utf-8") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=1)

print("\n=== 资产类型统计 ===")
for k, v in sorted(type_count.items(), key=lambda x: -x[1]):
    print(f"{k:20s} {v}")
print(f"\n共 {len(catalog)} 条 → {OUT}")

# 重点类型明细
for focus in ("Texture2D", "AudioClip", "Mesh", "Material", "TextAsset"):
    items = [c for c in catalog if c["type"] == focus]
    if items:
        print(f"\n=== {focus} ({len(items)}) 前60 ===")
        for c in items[:60]:
            print(f"  {c['name'][:40]:40s} {c['container'][:50]:50s} {c['size']}")
