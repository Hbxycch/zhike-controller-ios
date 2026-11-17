# -*- coding: utf-8 -*-
"""深挖第三批日志中的高速空转段与 w11 量程"""
import csv, statistics as st

rows = []
with open(r"D:/tools/MyData/WeiXin/xwechat_files/myweixin_cch_5044/msg/file/2026-11/frames(3).csv", encoding="utf-8") as f:
    for r in csv.DictReader(f):
        rows.append(r)
S = lambda r, i: int(r[f"w{i}"]) - 65536 if int(r[f"w{i}"]) >= 32768 else int(r[f"w{i}"])
W = lambda r, i: int(r[f"w{i}"])

# 找运动段
print("=== 逐帧时间线（w6>0 或 I!=0 的段）===")
active = False
seg = []
for i, r in enumerate(rows):
    moving = S(r,6) != 0 or S(r,9) != 0
    if moving and not active:
        start = i; active = True; seg = []
    if active:
        seg.append(r)
    if not moving and active:
        print(f"\n--- 段 {start}~{i-1}（{i-start}帧, {rows[start]['iso_time'][11:19]}~{rows[i-1]['iso_time'][11:19]}）---")
        for r in seg[::max(1, len(seg)//12)]:
            print(f"  t={r['iso_time'][11:19]} V={r['voltage_v']} I={S(r,9):>3} rpm={S(r,6):>5} w7={S(r,7):>5} w10={S(r,10):>5} w11={W(r,11):>6} w14={S(r,14):>5} w15={S(r,15):>5} w20={W(r,20)} w21={W(r,21)} thr={W(r,2)}")
        active = False
if active:
    print(f"\n--- 段 {start}~{len(rows)-1}（{len(rows)-start}帧）---")
    for r in seg[::max(1, len(seg)//12)]:
        print(f"  t={r['iso_time'][11:19]} V={r['voltage_v']} I={S(r,9):>3} rpm={S(r,6):>5} w7={S(r,7):>5} w10={S(r,10):>5} w11={W(r,11):>6} w14={S(r,14):>5} w15={S(r,15):>5} w20={W(r,20)} w21={W(r,21)} thr={W(r,2)}")

# w11 量程重新审视：与占空比/电流的关系
print("\n=== w11 vs I / rpm 相关性 ===")
nz = [(W(r,11), S(r,9), S(r,6), S(r,7)) for r in rows if S(r,6) > 100]
if nz:
    d = [x[0] for x in nz]; i_ = [abs(x[1]) for x in nz]; s = [x[2] for x in nz]; w7 = [abs(x[3]) for x in nz]
    def corr(a, b):
        ma, mb = st.mean(a), st.mean(b)
        num = sum((x-ma)*(y-mb) for x, y in zip(a, b))
        den = (sum((x-ma)**2 for x in a) * sum((y-mb)**2 for y in b)) ** 0.5
        return num/den if den else 0
    print(f"运动帧 {len(nz)} 个: w11 {min(d)}~{max(d)}")
    print(f"corr(w11,|I|)={corr(d,i_):.3f}  corr(w11,rpm)={corr(d,s):.3f}  corr(w11,|w7|)={corr(d,w7):.3f}")

# 官方截图工况：L挡 1017rpm/6A/相电流4.44 —— 在本批日志中找最近帧
print("\n=== 找 w7≈987(=4.44/0.0045) 的帧 ===")
hits = [r for r in rows if 900 <= abs(S(r,7)) <= 1100]
for r in hits[:8]:
    print(f"  t={r['iso_time'][11:19]} I={S(r,9)} rpm={S(r,6)} w7={S(r,7)} w11={W(r,11)} w14={S(r,14)} w15={S(r,15)}")
if not hits:
    print("  无。w7 分布：")
    import collections
    print("  ", sorted(set(S(r,7) for r in rows))[:20])

# w21 新取值含义：与制动/挡位相关？
print("\n=== w21 变化时前后帧对比 ===")
prev = None
for i, r in enumerate(rows):
    v = W(r,21)
    if prev is not None and v != prev:
        print(f"  {rows[i]['iso_time'][11:19]}: {bin(prev)} -> {bin(v)}  I={S(r,9)} rpm={S(r,6)} thr={W(r,2)} w20={W(r,20)}")
    prev = v

# 负电流段（回充/制动）细节
print("\n=== I<0 的帧 ===")
neg = [r for r in rows if S(r,9) < 0]
print(f"{len(neg)} 帧, I {min(S(r,9) for r in neg)}~{max(S(r,9) for r in neg)}, rpm {min(S(r,6) for r in neg) if neg else '-'}~{max(S(r,6) for r in neg) if neg else '-'}")
