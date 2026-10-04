#!/usr/bin/env python3
"""分批提取纹理: 每个子进程处理一批, 失败继续, 支持断点续传"""
import UnityPy, os, sys, json
DATA = "/home/z/my-project/dustline/Dustline_Data/ resources.assets"
DATA = "/home/z/my-project/dustline/Dustline_Data/resources.assets"
OUT = "/home/z/my-project/extract/assets/textures"
MANIFEST = "/home/z/my-project/extract/assets/texture_manifest.json"
ENGINE_TEX = ("LDR_LLL1_", "SearchTex", "AreaTex", "BayerMatrix", "DebugFont", "UIMask",
              "Medium0", "Medium1", "Large0", "Large1", "Large2", "Thin0", "Thin1", "Thin2",
              "Splash Screen Unity Logo", "default", "unity", "Default-")

mode = sys.argv[1]  # enum | extract
if mode == "enum":
    env = UnityPy.load(DATA)
    items = []
    for obj in env.objects:
        if obj.type.name == "Texture2D":
            items.append(obj.path_id)
    json.dump(items, open("/home/z/my-project/tools/tex_ids.json", "w"))
    print("枚举", len(items))
else:
    ids = json.load(open("/home/z/my-project/tools/tex_ids.json"))
    start, end = int(sys.argv[2]), int(sys.argv[3])
    manifest = json.load(open(MANIFEST)) if os.path.exists(MANIFEST) else {}
    env = UnityPy.load(DATA)
    done = 0
    for obj in env.objects:
        if obj.type.name != "Texture2D" or obj.path_id not in ids[start:end]:
            continue
        try:
            d = obj.read()
            name = d.m_Name or f"tex_{obj.path_id}"
            if any(name.startswith(p) for p in ENGINE_TEX) or name in manifest:
                done += 1
                continue
            img = d.image
            if img is None:
                continue
            fn = "".join(c for c in name if c.isalnum() or c in "-_. ") or f"tex_{obj.path_id}"
            img.save(f"{OUT}/{fn}.png")
            manifest[name] = {"file": fn + ".png", "w": img.width, "h": img.height}
            done += 1
            del img, d
        except Exception as e:
            print(f"err {obj.path_id}: {type(e).__name__}", flush=True)
    json.dump(manifest, open(MANIFEST, "w"))
    print(f"批次 {start}-{end}: 处理 {done}")
