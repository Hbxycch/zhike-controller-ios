# -*- coding: utf-8 -*-
"""分析智科控制器实车日志 frames(2).csv"""
import csv, sys, statistics as st

PATH = r"D:/tools/MyData/WeiXin/xwechat_files/myweixin_cch_5044/msg/file/2026-11/frames(2).csv"

rows = []
with open(PATH, encoding="utf-8-sig") as f:
    for r in csv.DictReader(f):
        rows.append(r)

n = len(rows)
print(f"帧数: {n}")
ok = sum(1 for r in rows if r["checksum_ok"] == "1")
print(f"校验通过: {ok}/{n} ({100*ok/n:.1f}%)")

# 时间跨度
from datetime import datetime
def t(r): return datetime.fromisoformat(r["iso_time"])
t0, t1 = t(rows[0]), t(rows[-1])
dur = (t1 - t0).total_seconds()
print(f"时长: {dur:.1f}s, 平均帧率: {n/dur:.1f} 帧/s")

W = lambda r, i: int(r[f"w{i}"])
def sw(r, i):  # 有符号
    v = W(r, i)
    return v - 65536 if v >= 32768 else v

# 每个字的活跃度
print("\n=== 各字活跃度（不同取值数 / min~max）===")
active = []
for i in range(32):
    vals = [W(r, i) for r in rows]
    u = len(set(vals))
    if u > 1:
        active.append((i, u, min(vals), max(vals)))
for i, u, lo, hi in active:
    print(f"w{i:<2} 取值{u:<5} {lo}~{hi}")
const = [i for i in range(32) if i not in [a[0] for a in active]]
print("恒定字:", const, "=", [W(rows[0], i) for i in const])

# 已知字段解码
print("\n=== 已知字段量级核查 ===")
volts = [W(r, 8) * 150 / 4096 * 0.1 for r in rows]
amps  = [sw(r, 9) for r in rows]
rpms  = [W(r, 6) / 5.46 for r in rows]
temps = [W(r, 18) / 100 for r in rows]
w2s   = [W(r, 2) for r in rows]
def rng(name, xs, fmt="{:.2f}"):
    print(f"{name:<10} min={fmt.format(min(xs))}  max={fmt.format(max(xs))}  avg={fmt.format(st.mean(xs))}")
rng("母线电压V", volts)
rng("母线电流A", amps, "{:.1f}")
rng("转速rpm", rpms, "{:.0f}")
rng("控制器温度C", temps)
rng("转把w2", w2s, "{:.0f}")

gears = sorted(set(W(r, 21) for r in rows))
faults = sorted(set(W(r, 22) for r in rows))
print("w21 挡位取值:", gears)
print("w22 故障取值:", [hex(f) for f in faults])

# 电压-电流相关性（负载下电压应下降 → 验证 w8/w9 正确性）
import math
va = [(W(r,8), sw(r,9)) for r in rows]
n_ = len(va)
mx = st.mean(v for v,_ in va); my = st.mean(a for _,a in va)
cov = sum((v-mx)*(a-my) for v,a in va)/n_
sx = math.sqrt(sum((v-mx)**2 for v,_ in va)/n_); sy = math.sqrt(sum((a-my)**2 for _,a in va)/n_)
print(f"\n电压-电流相关系数: {cov/(sx*sy):.3f}（负载时应为明显负值）")

# 找相电流候选：与母线电流相关性最高的变化字
print("\n=== 相电流候选字（与 w9 母线电流的相关性 Top）===")
target = [sw(r, 9) for r in rows]
cands = []
for i in range(32):
    xs = [W(r, i) for r in rows]
    if len(set(xs)) < 2: continue
    mx2 = st.mean(xs); mt = st.mean(target)
    c = sum((x-mx2)*(tt-mt) for x,tt in zip(xs,target))
    sx2 = math.sqrt(sum((x-mx2)**2 for x in xs)); stt = math.sqrt(sum((tt-mt)**2 for tt in target))
    if sx2 and stt:
        cands.append((c/(sx2*stt), i))
cands.sort(reverse=True)
for c, i in cands[:8]:
    xs = [W(r, i) for r in rows]
    print(f"w{i:<2} r={c:+.3f}  范围 {min(xs)}~{max(xs)}")

# 同样看与转速 w6 的相关
print("\n=== 与转速 w6 的相关性 Top ===")
target = [W(r, 6) for r in rows]
cands = []
for i in range(32):
    xs = [W(r, i) for r in rows]
    if len(set(xs)) < 2: continue
    mx2 = st.mean(xs); mt = st.mean(target)
    c = sum((x-mx2)*(tt-mt) for x,tt in zip(xs,target))
    sx2 = math.sqrt(sum((x-mx2)**2 for x in xs)); stt = math.sqrt(sum((tt-mt)**2 for tt in target))
    if sx2 and stt:
        cands.append((c/(sx2*stt), i))
cands.sort(reverse=True)
for c, i in cands[:8]:
    xs = [W(r, i) for r in rows]
    print(f"w{i:<2} r={c:+.3f}  范围 {min(xs)}~{max(xs)}")

# 温度变化
print(f"\n控制器温度: 开始 {temps[0]:.2f}C -> 结束 {temps[-1]:.2f}C, 峰值 {max(temps):.2f}C")

# 行驶工况概览：每10秒一个窗口
print("\n=== 工况时间线（每10秒）===")
import collections
win = collections.defaultdict(list)
for r in rows:
    sec = int((t(r) - t0).total_seconds()) // 10
    win[sec].append(r)
for s in sorted(win):
    rs = win[s]
    v = st.mean(W(r,8)*150/4096*0.1 for r in rs)
    a = max(sw(r,9) for r in rs)
    rpm = max(W(r,6)/5.46 for r in rs)
    w2 = max(W(r,2) for r in rs)
    print(f"t={s*10:>3}-{s*10+9:>3}s  V={v:6.1f}  I峰={a:5.1f}A  rpm峰={rpm:6.0f}  转把峰={w2}")
