#!/usr/bin/env python3
"""提取 Dustline 构建资产: Audio->wav, Texture->png, TextAsset, Sprite, 场景层级dump"""
import UnityPy, os, json, sys
from collections import defaultdict

DATA = "/home/z/my-project/dustline/Dustline_Data"
OUT = "/home/z/my-project/extract/assets"
os.makedirs(f"{OUT}/audio", exist_ok=True)
os.makedirs(f"{OUT}/textures", exist_ok=True)
os.makedirs(f"{OUT}/sprites", exist_ok=True)
os.makedirs(f"{OUT}/textassets", exist_ok=True)

# Unity 引擎内部纹理(跳过)
ENGINE_TEX = {"LDR_LLL1_", "SearchTex", "AreaTex", "BayerMatrix", "DebugFont", "UIMask",
              "Medium0", "Medium1", "Large0", "Large1", "Large2", "Thin0", "Thin1", "Thin2",
              "Splash Screen Unity Logo", "default"}
# 明确可辨识的 Valve 衍生资产(排除出构建, 单独存放)
VALVE_TEX = {"vistasmokev1"}

stats = defaultdict(int)
errors = []

def safe_name(n, used):
    n = "".join(c for c in n if c.isalnum() or c in "-_. ") or "unnamed"
    if n in used:
        used[n] += 1
        return f"{n}_{used[n]}"
    used[n] = 0
    return n

used_a, used_t, used_s, used_x = {}, {}, {}, {}

files = []
for f in sorted(os.listdir(DATA)):
    p = os.path.join(DATA, f)
    if f.endswith((".assets", ".bundle")) or f.startswith(("level", "sharedassets", "globalgamemanagers")):
        if not f.endswith((".resS", ".resource")):
            files.append(p)
print("加载:", [os.path.basename(x) for x in files])

scene_tree = []
for fp in files:
    env = UnityPy.load(fp)
    for obj in env.objects:
        td = obj.type.name
        try:
            if td == "AudioClip":
                d = obj.read()
                name = safe_name(d.m_Name or f"audio_{obj.path_id}", used_a)
                try:
                    samples = d.samples  # dict name->wav bytes
                    if isinstance(samples, dict):
                        for i, (k, wav) in enumerate(samples.items()):
                            fn = name if len(samples) == 1 else f"{name}_{i}"
                            open(f"{OUT}/audio/{fn}.wav", "wb").write(wav)
                            stats["audio"] += 1
                except Exception as e:
                    errors.append(f"audio {name}: {type(e).__name__} {e}")
            elif td == "Texture2D":
                d = obj.read()
                name = d.m_Name or f"tex_{obj.path_id}"
                if any(name.startswith(p) for p in ENGINE_TEX):
                    stats["tex_engine_skip"] += 1; continue
                sub = "valve_flagged" if any(name.startswith(v) for v in VALVE_TEX) else "textures"
                os.makedirs(f"{OUT}/{sub}", exist_ok=True)
                try:
                    img = d.image
                    img.save(f"{OUT}/{sub}/{safe_name(name, used_t)}.png")
                    stats["textures"] += 1
                except Exception as e:
                    errors.append(f"tex {name}: {type(e).__name__}")
            elif td == "Sprite":
                d = obj.read()
                name = d.m_Name or f"sprite_{obj.path_id}"
                try:
                    d.image.save(f"{OUT}/sprites/{safe_name(name, used_s)}.png")
                    stats["sprites"] += 1
                except Exception as e:
                    errors.append(f"sprite {name}: {type(e).__name__}")
            elif td == "TextAsset":
                d = obj.read()
                name = safe_name(d.m_Name or f"text_{obj.path_id}", used_x)
                try:
                    raw = d.m_Script
                    if isinstance(raw, str): raw = raw.encode("utf-8", "surrogateescape")
                    open(f"{OUT}/textassets/{name}.bin", "wb").write(raw)
                    stats["textassets"] += 1
                except Exception as e:
                    errors.append(f"text {name}: {type(e).__name__}")
        except Exception as e:
            errors.append(f"{td}: {type(e).__name__} {e}")

# 场景层级 dump (level0: GameObject+Transform)
print("\ndump 场景层级...")
env = UnityPy.load(os.path.join(DATA, "level0"))
gos, transforms = {}, {}
for obj in env.objects:
    if obj.type.name == "GameObject":
        d = obj.read()
        gos[obj.path_id] = {"name": d.m_Name, "components": [], "tag": getattr(d, "m_Tag", ""), "layer": d.m_Layer}
    elif obj.type.name == "Transform":
        d = obj.read()
        children = []
        try:
            children = [c.path_id for c in d.m_Children]
        except Exception: pass
        father = d.m_Father.path_id if d.m_Father else 0
        lp, lr = d.m_LocalPosition, d.m_LocalRotation
        transforms[obj.path_id] = {
            "go": d.m_GameObject.path_id, "parent": father, "children": children,
            "pos": [lp.x, lp.y, lp.z], "rot": [lr.x, lr.y, lr.z, lr.w]}

roots = [tid for tid, t in transforms.items() if t["parent"] not in transforms]
def build(tid):
    t = transforms[tid]
    node = {"name": gos.get(t["go"], {}).get("name", "?"), "pos": t["pos"], "rot": t["rot"], "children": []}
    for c in t["children"]:
        if c in transforms: node["children"].append(build(c))
    return node
tree = [build(r) for r in roots]
json.dump(tree, open("/home/z/my-project/extract/scene_tree.json", "w"), indent=1)
stats["scene_roots"] = len(roots)

print("\n=== 提取统计 ===")
for k, v in sorted(stats.items()): print(f"  {k}: {v}")
print(f"错误: {len(errors)}")
for e in errors[:10]: print("  ", e)
