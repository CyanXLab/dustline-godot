#!/usr/bin/env python3
"""提取原版所有 Texture2D → PNG（含 Resources/SourceContent/textures 材质贴图）
输出: /home/z/my-project/extract/assets/textures/<name>.png
统计引擎内部纹理并跳过, 记录尺寸/格式清单到 texture_manifest.json
"""
import UnityPy, os, json, sys
from collections import defaultdict

DATA = "/home/z/my-project/dustline/Dustline_Data"
OUT = "/home/z/my-project/extract/assets/textures"
os.makedirs(OUT, exist_ok=True)

ENGINE_TEX = ("LDR_LLL1_", "SearchTex", "AreaTex", "BayerMatrix", "DebugFont", "UIMask",
              "Medium0", "Medium1", "Large0", "Large1", "Large2", "Thin0", "Thin1", "Thin2",
              "Splash Screen Unity Logo", "default", "unity", "Default-")

stats = defaultdict(int)
errors = []
manifest = {}

files = []
for f in sorted(os.listdir(DATA)):
    p = os.path.join(DATA, f)
    if f.endswith((".assets", ".bundle")) or f.startswith(("level", "sharedassets", "globalgamemanagers")):
        if not f.endswith((".resS", ".resource")):
            files.append(p)
print("扫描:", [os.path.basename(x) for x in files], flush=True)

for fp in files:
    try:
        env = UnityPy.load(fp)
    except Exception as e:
        errors.append(f"load {fp}: {e}"); continue
    for obj in env.objects:
        if obj.type.name != "Texture2D":
            continue
        try:
            d = obj.read()
            name = d.m_Name or f"tex_{obj.path_id}"
            if any(name.startswith(p) for p in ENGINE_TEX):
                stats["engine_skip"] += 1; continue
            if name in manifest:
                stats["dup"] += 1; continue
            img = d.image
            if img is None:
                stats["no_image"] += 1; continue
            fn = "".join(c for c in name if c.isalnum() or c in "-_. ") or f"tex_{obj.path_id}"
            img.save(f"{OUT}/{fn}.png")
            manifest[name] = {"file": fn + ".png", "w": img.width, "h": img.height,
                              "fmt": str(d.m_TextureFormat), "path_id": obj.path_id}
            stats["textures"] += 1
        except Exception as e:
            errors.append(f"{obj.type.name} {obj.path_id}: {type(e).__name__} {e}")

json.dump(manifest, open(f"{OUT}/../texture_manifest.json", "w"), indent=1)
print("\n=== 纹理提取统计 ===")
for k, v in sorted(stats.items()): print(f"  {k}: {v}")
print(f"唯一纹理: {len(manifest)}")
print(f"错误: {len(errors)}")
for e in errors[:12]: print("  ", e)
