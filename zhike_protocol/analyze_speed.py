# -*- coding: utf-8 -*-
"""定位转速：滞后自相关 + 起步爬坡 + 滑行衰减"""
import csv, statistics as st, math
rows = list(csv.DictReader(open(r"D:/tools/MyData/WeiXin/xwechat_files/myweixin_cch_5044/msg/file/2026-11/frames(2).csv", encoding="utf-8-sig")))
W = lambda r,i: int(r[f"w{i}"])
def sw(r,i):
    v=W(r,i); return v-65536 if v>=32768 else v

print("=== 字段等值检查 ===")
e13 = sum(1 for r in rows if W(r,1)==W(r,3))
e1415 = sum(1 for r in rows if abs(W(r,14)-W(r,15))<30)
print(f"w1==w3: {e13}/{len(rows)}   |w14-w15|<30: {e1415}/{len(rows)}")

cands = [1,3,4,6,7,10,11,13,14,15]
print("\n=== 骑行段 lag-1 自相关（速度信号应较高）===")
riding_idx = [k for k,r in enumerate(rows) if abs(sw(r,9))>3 or W(r,2)>3000]
res=[]
for i in cands:
    xs=[sw(rows[k],i) for k in riding_idx]
    n=len(xs); mx=st.mean(xs)
    num=sum((xs[k]-mx)*(xs[k+1]-mx) for k in range(n-1))
    den=sum((x-mx)**2 for x in xs)
    res.append((num/den if den else 0, i))
for c,i in sorted(res, reverse=True):
    print(f"w{i:<2} lag1自相关={c:.3f}")

print("\n=== 起步事件：从静止(w6=0 连续)到给转把 ===")
# 找静止 -> 起步转换
prev_moving = False
events = []
for k,r in enumerate(rows):
    moving = W(r,6)!=0 or W(r,10)!=0
    if not prev_moving and moving and k>5:
        events.append(k)
    prev_moving = moving
print("起步帧索引:", events[:6])
for k in events[:3]:
    print(f"\n--- 起步 @ {rows[k]['iso_time'][11:19]} ---")
    for j in range(max(0,k-2), min(len(rows), k+16), 2):
        r=rows[j]
        print(f"  w2={W(r,2):5d} w9={sw(r,9):4d} | w6={sw(r,6):5d} w7={sw(r,7):5d} w10={W(r,10):5d} w11={W(r,11):5d} w14={sw(r,14):5d} w15={sw(r,15):5d} w1={sw(r,1):5d}")

print("\n=== 滑行段：松转把后谁在缓慢衰减 ===")
# 找：前一帧 w2>3500，本帧 w2<2300（突然松把）
coasts=[]
for k in range(1,len(rows)):
    if W(rows[k-1],2)>3500 and W(rows[k],2)<2350 and sw(rows[k-1],9)>5:
        coasts.append(k)
print("松把点:", coasts[:8])
for k in coasts[:4]:
    print(f"\n--- 松把 @ {rows[k]['iso_time'][11:19]} ---")
    for j in range(k, min(len(rows), k+14), 2):
        r=rows[j]
        print(f"  w2={W(r,2):5d} w9={sw(r,9):4d} | w6={sw(r,6):5d} w7={sw(r,7):5d} w10={W(r,10):5d} w11={W(r,11):5d} w14={sw(r,14):5d} w15={sw(r,15):5d}")

# 各候选除以常见系数后的峰值
print("\n=== 候选速度峰值换算 ===")
for i in [6,7,10,11]:
    mx = max(sw(r,i) for r in rows)
    print(f"w{i} 峰值 {mx}: /5.46={mx/5.46:.0f}rpm  /2={mx/2:.0f}  /1={mx}")
