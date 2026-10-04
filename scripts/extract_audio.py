#!/usr/bin/env python3
"""两段式音频提取: pass1枚举清单, pass2分块子进程解码FADPCM->wav"""
import UnityPy, os, json, sys, subprocess

DATA = "/home/z/my-project/dustline/Dustline_Data"
OUT = "/home/z/my-project/extract/assets/audio"
os.makedirs(OUT, exist_ok=True)
MANIFEST = "/home/z/my-project/extract/audio_manifest.json"

def pass1():
    manifest = []
    files = [os.path.join(DATA, f) for f in sorted(os.listdir(DATA))
             if (f.endswith(".assets") or f.startswith(("level", "sharedassets", "globalgamemanagers"))) and not f.endswith((".resS", ".resource"))]
    for fp in files:
        env = UnityPy.load(fp)
        for obj in env.objects:
            if obj.type.name == "AudioClip":
                d = obj.read()
                r = d.m_Resource
                if d.m_AudioData:
                    src, off, size = "__inline__", 0, len(d.m_AudioData)
                elif r:
                    src, off, size = r.m_Source, r.m_Offset, r.m_Size
                else:
                    continue
                manifest.append({"name": d.m_Name, "source": src, "offset": off, "size": size,
                                 "channels": d.m_Channels or 1, "freq": d.m_Frequency or 44100})
    json.dump(manifest, open(MANIFEST, "w"))
    print(f"清单: {len(manifest)} 个音频")

def decode_chunk(chunk, chunk_id):
    """在独立子进程中解码一块"""
    script = f"""
import fmod_toolkit, json, os, sys
manifest = json.load(open("{MANIFEST}"))
chunk = manifest[{chunk_id * 150}:{(chunk_id + 1) * 150}]
data = None; cur_src = None
ok, fail = 0, 0
for c in chunk:
    try:
        if c["source"] == "__inline__":
            raise ValueError("inline")
        if c["source"] != cur_src:
            cur_src = c["source"]
            data = open(os.path.join("{DATA}", cur_src), "rb").read()
        raw = data[c["offset"]:c["offset"] + c["size"]]
        out = fmod_toolkit.raw_to_wav(raw, c["name"], c["channels"], c["freq"])
        for fn, wav in out.items():
            open("{OUT}/" + fn, "wb").write(wav)
        ok += 1
    except Exception as e:
        fail += 1
print(json.dumps({{"chunk": {chunk_id}, "ok": ok, "fail": fail}}))
"""
    r = subprocess.run([sys.executable, "-c", script], capture_output=True, text=True, timeout=600)
    if r.returncode != 0:
        print(f"chunk {chunk_id} 失败: {r.stderr[-200:]}")
        return {"ok": 0, "fail": len(chunk)}
    return json.loads(r.stdout.strip().splitlines()[-1])

if __name__ == "__main__":
    if not os.path.exists(MANIFEST) or "--remanifest" in sys.argv:
        pass1()
    manifest = json.load(open(MANIFEST))
    nchunks = (len(manifest) + 149) // 150
    total_ok = total_fail = 0
    for i in range(nchunks):
        r = decode_chunk(manifest, i)
        total_ok += r["ok"]; total_fail += r["fail"]
        print(f"  块 {i+1}/{nchunks}: 成功{r['ok']} 失败{r['fail']}")
    print(f"总计: 成功 {total_ok} / {len(manifest)}，实际文件: {len(os.listdir(OUT))}")
