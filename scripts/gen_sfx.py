#!/usr/bin/env python3
"""程序化合成原创音效 SFX → 44.1kHz 16bit mono wav"""
import numpy as np, wave, os, random

SR = 44100
OUT = "/home/z/my-project/dustline-godot/assets/sfx"
os.makedirs(OUT, exist_ok=True)
rng = np.random.default_rng(4717)

def save(name, sig, gain=0.9):
    sig = np.asarray(sig, dtype=np.float64)
    m = np.max(np.abs(sig)) or 1.0
    sig = sig / m * gain
    data = (sig * 32767).astype(np.int16)
    with wave.open(f"{OUT}/{name}.wav", "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(data.tobytes())

def t(dur): return np.linspace(0, dur, int(SR*dur), endpoint=False)

def env_exp(n, k): return np.exp(-np.linspace(0, k, n))
def env_ar(n, a, r):
    e = np.ones(n); na=int(n*a); nr=int(n*r)
    if na>0: e[:na]=np.linspace(0,1,na)
    if nr>0: e[-nr:]*=np.linspace(1,0,nr)
    return e

def lowpass(x, alpha):
    y = np.empty_like(x); acc=0.0
    for i,v in enumerate(x):
        acc += alpha*(v-acc); y[i]=acc
    return y

def lowpass_fft(x, cutoff):
    X = np.fft.rfft(x); f = np.fft.rfftfreq(len(x), 1/SR)
    X *= 1/(1+(f/cutoff)**4)
    return np.fft.irfft(X, len(x))

def highpass_fft(x, cutoff):
    X = np.fft.rfft(x); f = np.fft.rfftfreq(len(x), 1/SR)
    X *= 1 - 1/(1+(f/cutoff)**4)
    return np.fft.irfft(X, len(x))

def bandpass_fft(x, lo, hi):
    X = np.fft.rfft(x); f = np.fft.rfftfreq(len(x), 1/SR)
    X *= (1/(1+(f/hi)**4)) * (1 - 1/(1+(f/lo)**4))
    return np.fft.irfft(X, len(x))

def noise(n): return rng.standard_normal(n)

def gunshot(dur=0.5, punch=110, body=70, bright=4500, tail=0.35, boom=0.5):
    n = int(SR*dur)
    click = highpass_fft(noise(n), 3000) * env_exp(n, 400)          # 撞击瞬态
    crack = bandpass_fft(noise(n), 1200, bright) * env_exp(n, 60)   # 爆裂
    thump = np.sin(2*np.pi*punch*t(dur)*np.exp(-t(dur)*8)) * env_exp(n, 30)  # 低频punch
    sub   = np.sin(2*np.pi*body*t(dur)) * env_exp(n, 18) * boom
    tn = int(SR*tail)
    tailn = lowpass_fft(noise(n), 900) * env_ar(n, 0.02, 0.98) * 0.4      # 尾音回散
    sig = click*0.9 + crack*1.0 + thump*0.8 + sub*0.9 + tailn
    return sig

def layer(*sigs):
    n = max(len(s) for s in sigs)
    out = np.zeros(n)
    for s in sigs: out[:len(s)] += s
    return out

def mix(*sigs): return layer(*sigs)

def delayed(sig, sec, g=0.5):
    d = np.zeros(int(SR*sec) + len(sig)); d[int(SR*sec):int(SR*sec)+len(sig)] = sig*g
    return d

# ---------------- 枪声（3把原创武器，音色区分） ----------------
save("shot_r77", layer(gunshot(punch=120, body=75, bright=5200, boom=0.55),
                       delayed(gunshot(dur=0.25, boom=0.2), 0.06, 0.25)), 0.85)
save("shot_s9",  layer(gunshot(dur=0.35, punch=150, body=95, bright=6500, tail=0.22, boom=0.35),), 0.8)
save("shot_dmr", layer(gunshot(dur=0.7, punch=95, body=60, bright=4200, tail=0.55, boom=0.8),
                       delayed(gunshot(dur=0.3, boom=0.3), 0.09, 0.3)), 0.95)

# ---------------- 弹道/命中 ----------------
save("bullet_crack", highpass_fft(noise(int(SR*0.03)), 2500)*env_exp(int(SR*0.03), 150), 0.7)
sw = np.sin(2*np.pi*np.linspace(3200, 700, int(SR*0.28))*t(0.28)**0.5*8)*env_exp(int(SR*0.28), 8)
save("ricochet", bandpass_fft(sw+noise(int(SR*0.28))*0.2, 500, 4500), 0.5)
for mat,(f,dur,g) in {"impact_concrete":(900,0.18,0.9),"impact_sand":(280,0.14,0.8)}.items():
    n=int(SR*dur); save(mat, lowpass_fft(noise(n), f*2)*env_exp(n,45)*g, 0.75)
n=int(SR*0.3); ring=np.sin(2*np.pi*780*t(0.3))*env_exp(n,14)*0.5+np.sin(2*np.pi*1230*t(0.3))*env_exp(n,20)*0.3
save("impact_metal", layer(lowpass_fft(noise(n),2500)*env_exp(n,50), ring), 0.7)
n=int(SR*0.12); save("impact_flesh", lowpass_fft(noise(n),350)*env_exp(n,40), 0.8)
n=int(SR*0.25); tink=layer(np.sin(2*np.pi*4400*t(0.25))*env_exp(n,40), np.sin(2*np.pi*6100*t(0.25))*env_exp(n,60)*0.6)
save("shell_drop", tink+noise(n)*env_exp(n,80)*0.1, 0.45)

# ---------------- 手雷 ----------------
n=int(SR*0.25); save("throw_whoosh", bandpass_fft(noise(n), 400, 1800)*env_ar(n,0.4,0.6), 0.55)
dur=1.4; n=int(SR*dur)
boom = layer(np.sin(2*np.pi*np.linspace(130,38,int(SR*0.5))*t(0.5)*3)*env_exp(int(SR*0.5),9),
             lowpass_fft(noise(n),1400)*env_exp(n,11),
             delayed(lowpass_fft(noise(int(SR*0.5)),500)*env_exp(int(SR*0.5),7),0.15,0.5))
save("explosion", boom, 1.0)
n=int(SR*0.08); save("grenade_bounce", layer(np.sin(2*np.pi*2400*t(0.08))*env_exp(n,50), lowpass_fft(noise(n),3000)*env_exp(n,60)*0.6), 0.5)

# ---------------- 换弹 ----------------
def click(f, dur=0.05, g=1.0):
    n=int(SR*dur); return (np.sin(2*np.pi*f*t(dur))*env_exp(n,70) + lowpass_fft(noise(n),f*3)*env_exp(n,80))*g
save("reload_magout", layer(click(300,0.06), delayed(lowpass_fft(noise(int(SR*0.1)),1800)*env_exp(int(SR*0.1),35),0.05,0.7)), 0.6)
save("reload_magin", layer(click(450,0.05), click(220,0.08)*0.9, delayed(click(350),0.04,0.6)), 0.7)
save("reload_bolt", layer(click(600,0.04), delayed(click(500,0.05),0.09,0.9), delayed(click(750,0.04),0.17,0.8)), 0.65)
save("empty_click", click(900,0.04,0.9), 0.5)

# ---------------- 脚步 ----------------
for i in range(3):
    n=int(SR*0.09)
    save(f"step_concrete_{i+1}", bandpass_fft(noise(n), 300, 2600)*env_exp(n,55)*(0.8+0.3*rng.random()), 0.5)
    save(f"step_dirt_{i+1}", lowpass_fft(noise(n), 900)*env_exp(n,60)*(0.8+0.3*rng.random()), 0.5)

# ---------------- 反馈/UI ----------------
save("hitmarker", layer(click(1050,0.045,1.0), delayed(click(1400,0.03),0.01,0.4)), 0.55)
save("hitmarker_head", layer(click(2100,0.05,1.0), np.sin(2*np.pi*2650*t(0.07))*env_exp(int(SR*0.07),30)*0.6), 0.55)
save("kill_confirm", layer(click(880,0.06), delayed(click(1320,0.08),0.07,1.0)), 0.6)
save("damage_taken", layer(lowpass_fft(noise(int(SR*0.15)),400)*env_exp(int(SR*0.15),35), np.sin(2*np.pi*85*t(0.15))*env_exp(int(SR*0.15),25)*0.7), 0.7)
save("ui_click", click(700,0.03,0.8), 0.4)
save("ui_hover", click(500,0.02,0.5), 0.25)
def beep(f,d,g=0.8):
    n=int(SR*d); return np.sin(2*np.pi*f*t(d))*env_ar(n,0.05,0.15)*g
save("round_start", layer(beep(880,0.12), delayed(beep(880,0.12),0.2), delayed(beep(1320,0.4),0.4)), 0.6)
saw=np.sign(np.sin(2*np.pi*220*t(0.9)))*0.3+np.sign(np.sin(2*np.pi*277*t(0.9)))*0.3+np.sign(np.sin(2*np.pi*330*t(0.9)))*0.3
save("wave_start", lowpass_fft(saw*env_ar(int(SR*0.9),0.3,0.4), 1200), 0.55)
def chord(fs, dur, ar=(0.1,0.5), g=0.3):
    n=int(SR*dur); s=sum(np.sin(2*np.pi*f*t(dur)) for f in fs)
    return s*env_ar(n,*ar)*g
save("victory", layer(chord([523,659,784],0.25), delayed(chord([587,740,880],0.25),0.22), delayed(chord([659,830,988],0.7,(0.05,0.6)),0.44,1.0)), 0.7)
save("defeat", layer(chord([440,523],0.3,(0.05,0.5)), delayed(chord([415,494],0.4,(0.05,0.5)),0.25), delayed(chord([349,415],0.9,(0.05,0.7)),0.5)), 0.7)

# ---------------- 环境风声（可循环） ----------------
dur=8.0; n=int(SR*dur)
brown=np.cumsum(noise(n)); brown-=np.linspace(brown[0],brown[-1],n); brown/=np.max(np.abs(brown))
lfo=0.6+0.4*np.sin(2*np.pi*0.13*t(dur)+1.2)*np.sin(2*np.pi*0.07*t(dur))
wind=lowpass_fft(brown*lfo, 480)
xf=int(SR*0.5)  # 首尾交叉淡化保证无缝循环
w=wind.copy(); w[:xf]=w[:xf]*np.linspace(0,1,xf)+w[-xf:]*np.linspace(1,0,xf); w=w[:-xf]
save("amb_wind", w, 0.5)

print("SFX 生成完成:", len(os.listdir(OUT)), "个文件")
