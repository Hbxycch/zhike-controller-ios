# -*- coding: utf-8 -*-
"""用官方 APP 截图真值校准：转速、转把电压、相电流、12V 电源"""
import csv, statistics as st
rows = list(csv.DictReader(open(r"E:/Backup/WorkBuddy/2026-11-16-15-59-58/zhike_protocol/real-log-frames.csv", encoding="utf-8-sig")))
W = lambda r,i: int(r[f"w{i}"])
def sw(r,i):
    v=W(r,i); return v-65536 if v>=32768 else v

print("=== 真值点 ===")
print("截图1(静止): 转把0.86V 转速0 母线0A 相0A 控制器18.58C 12V=14.41V")
print("截图2: 转把1.27V 母线6A 转速1016.48 相4.35A")
print("截图4: 转把1.39V 母线5A 相8A 转速999 8km/h")
print()

# 1) 转把电压换算: 0.86V <-> w2~2100
print("=== 转把: 假设 V = w2 × k ===")
for w2v, vv in [(2100,0.86),(3101,1.27),(3394,1.39)]:
    print(f"  w2={w2v} → {vv}V: k={vv/w2v*1e6:.1f} uV/unit")
k = 0.86/2100
w2_lo = 0.86/k; w2_hi = 1.27/k
print(f"  k={k*1e6:.0f}uV → 1.27V 对应 w2={w2_lo:.0f}, 1.39V 对应 {1.39/k:.0f}")

# 2) 转速: 官方 8km/h→999rpm。昨日 w6 分布
print("\n=== 转速判定: rpm = w6 直接读 or /5.46 ===")
ride = [r for r in rows if sw(r,9)>3]
print(f"昨日骑行段 w6: min={min(sw(r,6) for r in ride)} max={max(sw(r,6) for r in ride)} mean={st.mean(sw(r,6) for r in ride):.0f}")
print("若 rpm=w6: 峰值1398rpm→约11km/h(与官方8km/h→999rpm 线性一致)")
print("若 rpm=w6/5.46: 峰值256rpm→约2km/h, 与2.5分钟骑行+43A矛盾 → 排除")

# 3) 找官方截图对应的帧: 母线5~6A 且转把 1.2~1.4V
print("\n=== w9∈{5,6} 的帧（找相电流对应字）===")
hits = [r for r in rows if sw(r,9) in (5,6)]
print(f"共 {len(hits)} 帧, 按转把电压分区:")
for r in hits:
    w2v = W(r,2)*k
    print(f"  w9={sw(r,9)} 转把={w2v:.2f}V(w2={W(r,2)}) w6={sw(r,6)} w7={sw(r,7):5d} w10={W(r,10):5d} w11={W(r,11):5d} w14={sw(r,14):5d} w15={sw(r,15):5d} w1={sw(r,1):5d}")

# 4) 相电流 4.35A→435, 8A→800: 哪个字在这些帧附近出现该量级
print("\n=== 相电流候选(/100 后) ===")
for i in [1,7,10,14,15]:
    xs=[sw(r,i)/100 for r in hits]
    print(f"w{i}/100: {min(xs):.2f}~{max(xs):.2f} mean={st.mean(xs):.2f}")

# 5) 12V 电源: w16 -> 14.41V?
print("\n=== 12V 电源校准 ===")
w16 = [W(r,16) for r in rows]
print(f"w16: {min(w16)}~{max(w16)}  14.41/{st.mean(w16):.1f} = {14.41/st.mean(w16):.6f} V/count  (19/4096={19/4096:.6f})")

# 6) 控制器温度精确对照
print("\n=== 温度对照: 官方 18.58C(今晚) / 19C ===")
w18 = [W(r,18)/100 for r in rows]
print(f"昨日 w18/100: {min(w18):.2f}~{max(w18):.2f} — 与官方 /100 格式吻合")

# 7) w17 恒定 ~2100: 若是环境温度 21C
print(f"\nw17/100 = {min(W(r,17) for r in rows)/100:.2f}~{max(W(r,17) for r in rows)/100:.2f} (疑似环境温度)")
