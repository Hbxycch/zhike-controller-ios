# -*- coding: utf-8 -*-
"""电流候选字回归分析 + w23 温度时间线"""
import csv, statistics as st
rows = list(csv.DictReader(open(r"D:/tools/MyData/WeiXin/xwechat_files/myweixin_cch_5044/msg/file/2026-11/frames(2).csv", encoding="utf-8-sig")))
W = lambda r,i: int(r[f"w{i}"])
def sw(r,i):
    v=W(r,i); return v-65536 if v>=32768 else v

print("=== w10/w7/w11/w14 对母线电流 w9 的线性回归（骑行段，w9>0）===")
ride = [r for r in rows if sw(r,9) > 2]
print(f"样本 {len(ride)} 帧")
for i in [7,10,11,14,15,1]:
    xs=[sw(r,9) for r in ride]; ys=[sw(r,i) for r in ride]
    mx,my=st.mean(xs),st.mean(ys)
    cov=sum((a-mx)*(b-my) for a,b in zip(xs,ys))
    var=sum((a-mx)**2 for a in xs)
    k=cov/var; b=my-k*mx
    # 残差
    res=[abs(yv-(k*xv+b)) for xv,yv in zip(xs,ys)]
    print(f"w{i:<2} 斜率={k:8.2f} 截距={b:8.1f} 平均残差={st.mean(res):7.1f}  → 若=w9×k, 43A 时 = {43*k:.0f}")

print("\n=== w23 时间线（每 50 帧）===")
for k in range(0,len(rows),50):
    r=rows[k]
    print(f"t={r['iso_time'][11:19]}  w23={W(r,23)} ({W(r,23)/10:.1f}C?)  w18={W(r,18)/100:.2f}C  w16={W(r,16)/100:.2f} w17={W(r,17)/100:.2f}  w9={sw(r,9)}A  w6={sw(r,6)}")

print("\n=== w16/w17/w18/w23 的 lag-1 与慢变统计 ===")
for i in [16,17,18,23]:
    xs=[W(r,i) for r in rows]
    n=len(xs); mx=st.mean(xs)
    num=sum((xs[k]-mx)*(xs[k+1]-mx) for k in range(n-1)); den=sum((x-mx)**2 for x in xs)
    print(f"w{i:<2} min={min(xs)} max={max(xs)} lag1={num/den:.4f}")

print("\n=== 相位和检验：w13+w14+w15 ===")
sums=[sw(r,13)+sw(r,14)+sw(r,15) for r in rows if sw(r,9)>2]
print(f"骑行段 |和|: min={min(map(abs,sums))} max={max(map(abs,sums))} 均值={st.mean(sums):.0f}")

print("\n=== w1/w15、w3/w15 比值 ===")
rs=[sw(r,1)/sw(r,15) for r in rows if abs(sw(r,15))>500]
print(f"w1/w15: 均值={st.mean(rs):.3f} std={st.pstdev(rs):.3f} n={len(rs)}")
rs2=[(sw(r,14)+sw(r,15))/2/sw(r,1) for r in rows if abs(sw(r,1))>500]
print(f"(w14+w15)/2 / w1: 均值={st.mean(rs2):.3f} std={st.pstdev(rs2):.3f}")
