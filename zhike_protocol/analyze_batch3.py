# -*- coding: utf-8 -*-
"""第三批实机数据复核：205 帧，官方截图真值（L挡巡航 1017.03rpm / 6A / 相电流 4.44A）"""
import csv, statistics as st

rows = []
with open(r"D:/tools/MyData/WeiXin/xwechat_files/myweixin_cch_5044/msg/file/2026-11/frames(3).csv", encoding="utf-8") as f:
    for r in csv.DictReader(f):
        rows.append(r)

W = lambda r, i: int(r[f"w{i}"])
S = lambda r, i: st.i16 if False else int(r[f"w{i}"]) - 65536 if int(r[f"w{i}"]) >= 32768 else int(r[f"w{i}"])
ok = sum(int(r["checksum_ok"]) for r in rows)
print(f"总帧 {len(rows)}  校验通过 {ok} ({ok/len(rows)*100:.1f}%)")
ts = [r["iso_time"][11:19] for r in rows]
print(f"时间 {ts[0]} ~ {ts[-1]}  帧率 {len(rows)/47.0:.1f} fps")

volt = [float(r["voltage_v"]) for r in rows if r["voltage_v"]]
cur  = [S(r,9) for r in rows]
rpmW = [S(r,6) for r in rows]
w7   = [S(r,7) for r in rows]
w10  = [S(r,10) for r in rows]
w14  = [S(r,14) for r in rows]
w15  = [S(r,15) for r in rows]
w16  = [W(r,16) for r in rows]
w18  = [W(r,18) for r in rows]
w11  = [W(r,11) for r in rows]
w20  = [W(r,20) for r in rows]
w21  = [W(r,21) for r in rows]
w23  = [W(r,23) for r in rows]

print(f"\n母线电压: {min(volt):.2f}~{max(volt):.2f} V (官方 82.23/82.2)")
print(f"母线电流: {min(cur)}~{max(cur)} A (官方 0/6)")
print(f"w6 转速: {min(rpmW)}~{max(rpmW)} (官方 0/1017.03)")
nz = [x for x in rpmW if x > 0]
if nz: print(f"  非零转速段: {min(nz)}~{max(nz)}, 峰值官方换算 km/h 参考: 1017rpm↔8km/h → {max(nz)*8/1017:.1f}km/h")
print(f"控制器温度 w18/100: {min(w18)/100:.2f}~{max(w18)/100:.2f} ℃ (官方 16.4)")
print(f"12V w16*19/4096: {min(w16)*19/4096:.2f}~{max(w16)*19/4096:.2f} V (官方 14.4/14.42)")
print(f"转把电压 w2*0.0004096: {min(W(r,2) for r in rows)*0.0004096:.3f}~{max(W(r,2) for r in rows)*0.0004096:.3f} V (官方 0.86/1.29)")
print(f"PWM w11: {min(w11)}~{max(w11)} ({min(w11)/40.96:.0f}%~{max(w11)/40.96:.0f}%)")
print(f"相电流估算 w7*0.0045: {min(w7)*0.0045:.2f}~{max(w7)*0.0045:.2f} A (官方 0/4.44)")
print(f"w14 相采样: {min(w14)}~{max(w14)}   w15: {min(w15)}~{max(w15)}")
print(f"w20 取值: {sorted(set(w20))}   w21 取值: {sorted(set(w21))}")
print(f"w23: {min(w23)}~{max(w23)}")

# 与官方真值同工况对齐：找母线 6A 且转速 ~1017 的帧
print("\n=== 官方截图工况对齐 ===")
cand = [r for r in rows if abs(S(r,9) - 6) <= 1 and rpmW[rows.index(r)] > 900]
if cand:
    w7s = [S(r,7) for r in cand]
    r6s = [S(r,6) for r in cand]
    print(f"匹配帧 {len(cand)} 个: 母线6A±1, 转速>900")
    print(f"  w6 = {min(r6s)}~{max(r6s)}  (官方 1017.03)")
    print(f"  w7 = {min(w7s)}~{max(w7s)}  均值 {st.mean(w7s):.0f}")
    est = st.mean(w7s)*0.0045
    print(f"  相电流 w7*0.0045 = {est:.2f} A  vs 官方 4.44 A  误差 {(est-4.44)/4.44*100:+.1f}%")
    d11 = [W(r,11) for r in cand]
    print(f"  占空比 {st.mean(d11)/40.96:.0f}%  → 物理校验 6/(1.732*{st.mean(d11)/4096:.3f}) = {6/(1.732*st.mean(d11)/4096):.2f} A")
else:
    print("无母线6A+转速>900 的匹配帧，放宽搜索：")
    for r in rows[::20]:
        print(f"  {r['iso_time'][11:19]} V={r['voltage_v']} I={S(r,9)} rpm={S(r,6)} w7={S(r,7)} w10={S(r,10)} duty={W(r,11)}")

# 12V 与温度的时间稳定性
print("\n=== 慢变量稳定性 ===")
print(f"w16: {st.mean(w16):.0f}±{st.stdev(w16):.0f}  → 12V {st.mean(w16)*19/4096:.2f}±{st.stdev(w16)*19/4096*1000:.0f}mV")
print(f"w17/100: {min(W(r,17) for r in rows)/100:.2f}~{max(W(r,17) for r in rows)/100:.2f} ℃")
print(f"w18/100: {st.mean(w18)/100:.2f}±{st.stdev(w18)/100*100:.1f} ℃")

# 相电流 4.44A 帧的 w14/w15 包络
run = [r for r in rows if S(r,9) >= 4]
if run:
    u = [abs(S(r,14)) for r in run]; v = [abs(S(r,15)) for r in run]
    print(f"\n行驶段（I>=4A, {len(run)}帧）相采样包络 |w14|max={max(u)} |w15|max={max(v)}  均值 {st.mean(u):.0f}/{st.mean(v):.0f}")
