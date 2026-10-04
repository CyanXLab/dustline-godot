#!/usr/bin/env python3
"""分析 DSV1 顶点数据特征 → 设计优化格式"""
import struct
from collections import Counter, defaultdict

PATH = "/home/z/my-project/extract/assets/textassets/map.bin"
STRIDE = 56

data = open(PATH, "rb").read()
count, = struct.unpack_from("<I", data, 4)
off = 8
light_dist = Counter()
color_const = Counter()   # 每记录顶点色是否恒定
color_max = [0.0, 0.0, 0.0, 0.0]
uv_range = [1e30, 1e30, -1e30, -1e30]
uv2_range = [1e30, 1e30, -1e30, -1e30]
normal_int = Counter()    # 法线是否全为轴向整数
uv_tile = Counter()       # uv 最大值分布(分箱)
recs = 0
total_v = 0
sample_per_light = {}
while off < len(data):
    slen, = struct.unpack_from("<H", data, off); off += 2
    name = data[off:off+slen].decode(); off += slen
    light, vc, ic = struct.unpack_from("<iii", data, off); off += 12
    light_dist[light] += 1
    base = off
    cmin = [1e30]*4; cmax = [-1e30]*4
    umin = [1e30]*2; umax = [-1e30]*2
    vmin2 = [1e30]*2; vmax2 = [-1e30]*2
    axis_n = 0
    for v in range(vc):
        p = base + v*STRIDE
        # normal at +12
        nx, ny, nz = struct.unpack_from("<fff", data, p+12)
        if (abs(abs(nx)-1)+abs(ny)+abs(nz) < 1e-6 or abs(nx)+abs(abs(ny)-1)+abs(nz) < 1e-6
            or abs(nx)+abs(ny)+abs(abs(nz)-1) < 1e-6) and (nx in (0.0,-1.0,1.0) and ny in (0.0,-1.0,1.0) and nz in (0.0,-1.0,1.0)):
            axis_n += 1
        u1, v1 = struct.unpack_from("<ff", data, p+24)
        umin[0]=min(umin[0],u1); umax[0]=max(umax[0],u1)
        umin[1]=min(umin[1],v1); umax[1]=max(umax[1],v1)
        u2, v2 = struct.unpack_from("<ff", data, p+32)
        vmin2[0]=min(vmin2[0],u2); vmax2[0]=max(vmax2[0],u2)
        vmin2[1]=min(vmin2[1],v2); vmax2[1]=max(vmax2[1],v2)
        for c in range(4):
            cv = struct.unpack_from("<f", data, p+40+c*4)[0]
            cmin[c]=min(cmin[c],cv); cmax[c]=max(cmax[c],cv)
            color_max[c] = max(color_max[c], cv)
    total_v += vc
    # 色恒定判断
    is_const = all(abs(cmax[c]-cmin[c]) < 1e-6 for c in range(4))
    if is_const:
        key = tuple(round(cmax[c], 3) for c in range(4))
        color_const[key] += 1
    else:
        color_const["VARIES"] += 1
    # uv 分箱
    m = max(umax[0], umax[1], -umin[0], -umin[1])
    uv_tile[min(int(m), 200)] += 1
    uv_range = [min(uv_range[0],umin[0]), min(uv_range[1],umin[1]), max(uv_range[2],umax[0]), max(uv_range[3],umax[1])]
    if light >= 0:
        uv2_range = [min(uv2_range[0],vmin2[0]), min(uv2_range[1],vmin2[1]), max(uv2_range[2],vmax2[0]), max(uv2_range[3],vmax2[1])]
        sample_per_light[light] = sample_per_light.get(light, 0) + vc
    off += vc*STRIDE + ic*4
    recs += 1

print(f"记录 {recs} 顶点 {total_v}")
print(f"light 索引分布: {dict(light_dist)}")
print(f"光贴图顶点数: {sample_per_light}")
print(f"顶点色恒定分布(前8): {dict(list(color_const.items())[:8])}")
print(f"顶点色全局最大: {[round(x,3) for x in color_max]}")
print(f"UV 范围: {[round(x,2) for x in uv_range]}")
print(f"uv2(lightmap UV) 范围: {[round(x,4) for x in uv2_range]}")
print(f"轴向法线占比: {axis_n}/{total_v} = {axis_n/total_v:.1%}")
print(f"UV 最大值分箱(前15): {dict(sorted(uv_tile.items())[:15])}")
