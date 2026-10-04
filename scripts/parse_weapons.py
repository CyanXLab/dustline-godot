#!/usr/bin/env python3
"""解析 SourceWeaponData.cs → weapons.json (43把武器完整数据)"""
import re, json

SRC = "/home/z/my-project/extract/src/core/Dustline.Core/SourceWeaponData.cs"
OUT = "/home/z/my-project/extract/weapons.json"
text = open(SRC).read()

ctor = re.compile(
    r'new Weapon\("([^"]+)",\s*([\d.]+)f?,\s*([\d.]+)f?,\s*([\d.]+)f?,\s*([\d.]+)f?,\s*([\d.]+)f?,\s*(\d+),\s*(\d+),\s*([\d.]+)f?,\s*([\d.]+)f?,\s*automatic:\s*(true|false)\)',
)
assign = re.compile(r'(\w+)\s*=\s*([^,\n]+?)(?:f)?(?:,\s|\n|\r|$)')
str_assign = re.compile(r'(\w+)\s*=\s*"([^"]*)"')
enum_assign = re.compile(r'(\w+)\s*=\s*(WeaponKind\.\w+|WeaponSlot\.\w+)')

CTOR_FIELDS = ["name", "damage", "armor_ratio", "range_modifier", "cycle", "reload",
               "magazine", "reserve", "max_speed", "base_spread", "automatic"]
SKIP = {"Key", "Category"}

# 枚举映射
KIND = {"Firearm": 0, "Knife": 1, "Taser": 2, "Grenade": 3, "Bomb": 4}
SLOT = {"Primary": 0, "Secondary": 1, "Knife": 2, "Taser": 3, "Grenade": 4, "Bomb": 5}

weapons = []
for m in ctor.finditer(text):
    w = dict(zip(CTOR_FIELDS, m.groups()))
    for k in CTOR_FIELDS[1:-1]:
        w[k] = float(w[k]) if "." in str(w[k]) else int(w[k])
    w["automatic"] = w["automatic"] == "true"
    # 解析初始化块
    block_start = m.end()
    depth = 0; i = block_start
    # 跳过 "{"
    while text[i] != "{": i += 1
    start = i; depth = 0
    while True:
        if text[i] == "{": depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0: break
        i += 1
    block = text[start:i]
    w["key"] = ""
    for sm in str_assign.finditer(block):
        if sm.group(1) == "Key": w["key"] = sm.group(2)
        elif sm.group(1) == "Category": w["category"] = sm.group(2)
    for em in enum_assign.finditer(block):
        if em.group(1) == "Kind": w["kind"] = KIND[em.group(2).split(".")[1]]
        elif em.group(1) == "Slot": w["slot"] = SLOT[em.group(2).split(".")[1]]
    for am in assign.finditer(block):
        k, v = am.group(1), am.group(2).strip()
        if k in SKIP or k in ("Kind", "Slot") or "WeaponKind" in v or "WeaponSlot" in v: continue
        try:
            if v in ("true", "false"): w[k.lower()] = v == "true"
            elif re.fullmatch(r"-?\d+", v): w[k.lower()] = int(v)
            elif re.fullmatch(r"-?[\d.]+", v): w[k.lower()] = float(v)
        except Exception: pass
    weapons.append(w)

json.dump(weapons, open(OUT, "w"), indent=1)
print(f"解析出 {len(weapons)} 把武器 → {OUT}")
for w in weapons:
    print(f"  {w['name']:18s} key={w.get('key','?'):12s} dmg={w['damage']:6.1f} price={w.get('price',0):5d} slot={w.get('slot','?')} kind={w.get('kind','?')} cat={w.get('category','?')}")
