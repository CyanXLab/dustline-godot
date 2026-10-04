#!/usr/bin/env python3
"""按音频特征分类提取出的1613个wav → 规范化事件音效库"""
import wave, os, json, struct, shutil
import numpy as np

SRC = "/home/z/my-project/extract/assets/audio"
DST = "/home/z/my-project/dustline-godot/assets/sfx_extracted"
os.makedirs(DST, exist_ok=True)

def analyze(path):
    try:
        w = wave.open(path)
        n, sr, ch = w.getnframes(), w.getframerate(), w.getnchannels()
        if n == 0: return None
        dur = n / sr
        raw = w.readframes(min(n, sr * 3))
        w.close()
        data = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
        if ch > 1: data = data[::ch]
        rms = float(np.sqrt(np.mean(data ** 2)))
        peak = float(np.max(np.abs(data)))
        # 过零率
        zc = float(np.mean(np.abs(np.diff(np.sign(data))) > 0))
        # 频谱质心
        sp = np.abs(np.fft.rfft(data * 0.5)) ** 2
        f = np.fft.rfftfreq(len(data), 1 / sr)
        cent = float(np.sum(f * sp) / (np.sum(sp) + 1e-9))
        # 衰减速度: 前后段能量比
        n3 = len(data) // 3
        tail_ratio = float(np.mean(data[2*n3:] ** 2) / (np.mean(data[:n3] ** 2) + 1e-9))
        return {"dur": dur, "rms": rms, "peak": peak, "zc": zc, "cent": cent, "tail": tail_ratio}
    except Exception:
        return None

feats = []
for fn in sorted(os.listdir(SRC)):
    if not fn.endswith(".wav"): continue
    a = analyze(os.path.join(SRC, fn))
    if a: feats.append({"file": fn, **a})

print(f"分析 {len(feats)} 个音频")

def pick(score_fn, count, exclude=set(), min_dur=0, max_dur=999, seen_prefix=True):
    cands = [f for f in feats if f["file"] not in exclude and min_dur <= f["dur"] <= max_dur]
    cands.sort(key=score_fn, reverse=True)
    out = []
    used = set()
    for c in cands:
        if seen_prefix:
            pref = c["file"][:8]
            if pref in used: continue
            used.add(pref)
        out.append(c["file"])
        if len(out) >= count: break
    return out

picked = {}
# 枪声: 短、极响、高质心、快速衰减
picked["shot_rifle"] = pick(lambda f: f["rms"] * (f["cent"] / 1000) * (1 / (1 + f["dur"])), 12, max_dur=1.2)
ex = set(sum(picked.values(), []))
# 爆炸/大响: 长、响、低频
picked["explosion"] = pick(lambda f: f["rms"] * (1 / (1 + f["cent"] / 2000)), 6, ex, min_dur=1.0)
ex = set(sum(picked.values(), []))
# 脚步: 很短、安静、低频
picked["step"] = pick(lambda f: (1 - f["rms"]) * (1 / (1 + f["cent"] / 3000)) * (1 / (1 + abs(f["dur"] - 0.18) * 8)), 10, ex, min_dur=0.05, max_dur=0.5)
ex = set(sum(picked.values(), []))
# 金属叮: 高质心、短
picked["ric"] = pick(lambda f: f["cent"] * (1 / (1 + f["dur"])), 8, ex, min_dur=0.05, max_dur=0.8)
ex = set(sum(picked.values(), []))
# 击中: 中等
picked["hit"] = pick(lambda f: f["rms"] * (1 / (1 + f["cent"] / 800)), 8, ex, min_dur=0.03, max_dur=0.35)
ex = set(sum(picked.values(), []))
# UI/电子: 极短
picked["ui"] = pick(lambda f: (1 - f["rms"]) * (1 / (1 + abs(f["dur"] - 0.08) * 10)), 10, ex, min_dur=0.02, max_dur=0.25)
ex = set(sum(picked.values(), []))
# 环境: 长、安静
picked["ambient"] = pick(lambda f: (1 - f["rms"]) / (1 + abs(f["dur"] - 8) * 0.3), 4, ex, min_dur=3.0)
ex = set(sum(picked.values(), []))
# 其他留作通用
picked["misc"] = pick(lambda f: f["rms"], 16, ex, min_dur=0.1)

manifest = {}
count = 0
for cat, files in picked.items():
    manifest[cat] = []
    for i, fn in enumerate(files):
        shutil.copy(f"{SRC}/{fn}", f"{DST}/{cat}_{i:02d}.wav")
        manifest[cat].append(f"{cat}_{i:02d}.wav")
        count += 1
json.dump(manifest, open(f"{DST}/manifest.json", "w"), indent=1)
print(f"整理 {count} 个 → {DST}")
for k, v in manifest.items(): print(f"  {k}: {len(v)}")
