# -*- coding: utf-8 -*-
"""深挖帧结构：校验字、有符号重解释、平滑度定位转速"""
import csv, statistics as st, math
from datetime import datetime

PATH = r"D:/tools/MyData/WeiXin/xwechat_files/myweixin_cch_5044/msg/file/2026-11/frames(2).csv"
rows = list(csv.DictReader(open(PATH, encoding="utf-8-sig")))
W = lambda r, i: int(r[f"w{i}"])
def sw(r, i):
    v = W(r, i)
    return v - 65536 if v >= 32768 else v

# --- 1. 校验结构 ---
print("=== 校验结构验证（前5帧）===")
for r in rows[:5]:
    s31 = sum(W(r, i) for i in range(31)) & 0xFFFF
    s32 = sum(W(r, i) for i in range(32)) & 0xFFFF
    print(f"w31={W(r,31):5d}  sum(w0..30)&M={s31:5d}  ~s31={(~s31)&0xFFFF:5d}  sum32&M={s32:5d}")

# --- 2. 噪声字有符号分布 ---
print("\n=== 噪声字按 int16 解释 ===")
for i in [1,3,4,6,7,9,13,14,15,31]:
    xs = [sw(r,i) for r in rows]
    print(f"w{i:<2} min={min(xs):7d} max={max(xs):7d} mean={st.mean(xs):9.1f} std={st.pstdev(xs):9.1f}  |x|>1000 占比 {100*sum(1 for x in xs if abs(x)>1000)/len(xs):.0f}%")

# --- 3. 平滑度排名（找转速）---
print("\n=== 平滑度排名：帧间相对变化越小越平滑 ===")
# 只在骑行段（w9绝对值>3A 或 w2>3000）评估
riding = [r for r in rows if abs(sw(r,9))>3 or W(r,2)>3000]
print(f"骑行帧数 {len(riding)}/{len(rows)}")
scores = []
for i in range(32):
    xs = [W(r,i) for r in riding]
    rngv = max(max(xs)-min(xs), 1)
    jump = st.mean(abs(b-a) for a,b in zip(xs, xs[1:])) / rngv
    scores.append((jump, i, min(xs), max(xs)))
scores.sort()
for j, i, lo, hi in scores[:12]:
    print(f"w{i:<2} 跳变率={j:.3f}  范围 {lo}~{hi}")

# --- 4. w10/w11 与 w2 转把、w9 电流的滞后相关 ---
print("\n=== w10/w11 的时间序列采样（每50帧）===")
for k in range(0, len(rows), 50):
    r = rows[k]
    print(f"t={r['iso_time'][11:19]}  w6={W(r,6):5d} w7={W(r,7):5d} w9={sw(r,9):4d} w10={W(r,10):5d} w11={W(r,11):5d} w2={W(r,2):5d} w4={sw(r,4):6d} w13={sw(r,13):6d} w14={sw(r,14):6d} w15={sw(r,15):6d}")

# --- 5. 检查 w4/w6/w7/w13/w14/w15 是否为三相电流原始采样 ---
print("\n=== 骑行段各噪声字的均值（若为正弦采样，均值≈0）===")
for i in [4,6,7,13,14,15]:
    xs = [sw(r,i) for r in riding]
    print(f"w{i:<2} 骑行段 mean={st.mean(xs):8.1f} std={st.pstdev(xs):8.1f}")

# --- 6. w16/w17/w18/w23 候选温度 ---
print("\n=== 温度候选 ===")
for i,div in [(16,100),(17,100),(18,100),(23,10),(23,100)]:
    xs=[W(r,i)/div for r in rows]
    print(f"w{i}/{div}: {min(xs):.2f} ~ {max(xs):.2f}")

# --- 7. w20/w21 档位 ---
print("\n=== w20/w21 联合分布 ===")
from collections import Counter
c = Counter((W(r,20), W(r,21)) for r in rows)
for k,v in sorted(c.items()):
    print(f"w20={k[0]} w21={k[1]:4d} 帧数={v}")

# --- 8. w9=0 但 w2 大（下坡滑行?）与负电流帧 ---
neg = [r for r in rows if sw(r,9) < 0]
print(f"\n负电流帧数: {len(neg)}, 范围 {min(sw(r,9) for r in neg) if neg else '-'} ~ 0")
