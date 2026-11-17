#!/usr/bin/env python3
"""
用 frames.csv 里的 GPS 车速真值，标定 w6 -> 车速 的系数 K。

用法:
    python analyze_gps_calib.py <frames.csv> [轮胎周长mm]

判定逻辑:
  1. 过滤有效 GPS 点（gps_valid=1, 车速>3, 精度<15m, 对齐误差<2s）
  2. 过原点最小二乘 K = Σ(v·w6) / Σ(w6²)，单位 km/h 每 w6 单位
  3. 等效除数 D = 周长(m)×0.06 / K
     - D≈极对数 → w6 是电转速，换算正确
     - D 明显不是整数或与「电机组-极对数」不符 → w6 口径另有所指
  4. 分速度段复核线性度（K 是否随速度变化）
"""
import csv
import sys
import math
from collections import defaultdict


def load(path):
    rows = []
    with open(path, encoding="utf-8-sig") as f:
        for r in csv.DictReader(f):
            rows.append(r)
    return rows


def fnum(r, key, default=None):
    v = r.get(key, "")
    if v is None or v == "":
        return default
    try:
        return float(v)
    except ValueError:
        return default


def main():
    if len(sys.argv) < 2:
        print("用法: python analyze_gps_calib.py <frames.csv> [轮胎周长mm]")
        return
    path = sys.argv[1]
    circumference_mm = float(sys.argv[2]) if len(sys.argv) > 2 else 1529.0
    C = circumference_mm / 1000.0

    rows = load(path)
    total = len(rows)
    if total == 0:
        print("CSV 为空")
        return

    has_gps_cols = "gps_kmh" in rows[0]
    print(f"总帧数 {total}；GPS 列 {'存在' if has_gps_cols else '不存在（老版本 App 日志）'}")
    if not has_gps_cols:
        print("请用新版本 App（含 GPS 记录）重新采集。")
        return

    # ---- 1. 过滤 ----
    pairs = []       # (w6, gps, acc, age)
    rejected = defaultdict(int)
    for r in rows:
        w6 = fnum(r, "w6", 0.0)
        gps = fnum(r, "gps_kmh")
        acc = fnum(r, "gps_acc_m", 99.0) or 99.0
        age = fnum(r, "gps_age_s", 99.0) or 99.0
        valid = r.get("gps_valid", "0").strip() == "1"
        if not valid or gps is None:
            rejected["无有效GPS"] += 1
            continue
        if gps <= 3:
            rejected["车速过低"] += 1
            continue
        if acc > 15:
            rejected["精度差"] += 1
            continue
        if age > 2:
            rejected["时间不对齐"] += 1
            continue
        if w6 <= 100:
            rejected["转速过低"] += 1
            continue
        pairs.append((w6, gps, acc, age))

    print(f"\n有效配对 {len(pairs)} / {total} 帧（{len(pairs)/total*100:.1f}%）")
    for k, v in rejected.items():
        print(f"  剔除 {k}: {v}")

    if len(pairs) < 30:
        print("\n有效点太少，不足以标定。请延长带 GPS 的骑行时间（>60 秒）。")
        return

    # ---- 2. 过原点最小二乘 ----
    sxy = sum(w * v for w, v, _, _ in pairs)
    sxx = sum(w * w for w, _, _, _ in pairs)
    K = sxy / sxx

    # R²（对 y = Kx）
    ss_tot = sum(v * v for _, v, _, _ in pairs)
    ss_res = sum((v - K * w) ** 2 for w, v, _, _ in pairs)
    r2 = 1 - ss_res / ss_tot if ss_tot > 0 else float("nan")

    vmax = max(v for _, v, _, _ in pairs)
    w6max = max(w for w, _, _, _ in pairs)
    D = C * 0.06 / K if K > 0 else float("nan")

    print("\n=== 标定结果 ===")
    print(f"K = {K:.6f} km/h 每 w6 单位   (R² = {r2:.4f})")
    print(f"等效除数 D = 周长×0.06 / K = {D:.2f}")
    print(f"  → w6 {w6max:.0f} 时车速 {K*w6max:.1f} km/h（数据内最高 GPS {vmax:.1f}）")

    theory_K = C * 0.06 / 16
    print(f"\n理论值（P=16, 周长 {circumference_mm:.0f}mm）K = {theory_K:.6f}"
          f"  → w6 {w6max:.0f} 时应为 {theory_K*w6max:.1f} km/h")
    if K > 0:
        ratio = K / theory_K
        print(f"实测 / 理论 = {ratio:.3f}")
        if abs(ratio - 1) < 0.05:
            print("  ✅ 与理论一致：w6 是电转速、极对数 16 正确，换算链成立")
        else:
            print(f"  ⚠️ 偏差 {abs(ratio-1)*100:.0f}%，等效除数 {D:.2f} 才是真实口径"
                  f"（若 D 接近整数，可将极对数改为该值）")
            print(f"     建议：把设置里的极对数改为 {round(D)}，或直接用 K={K:.6f} 标定")

    # ---- 3. 分速度段线性度 ----
    buckets = defaultdict(list)
    for w, v, _, _ in pairs:
        edge = int(v // 10 * 10)
        buckets[edge].append((w, v))

    print("\n=== 分速度段复核（K 是否随速度漂移）===")
    print(" 车速段    点数  段内 K     段内平均车速")
    for edge in sorted(buckets):
        grp = buckets[edge]
        if len(grp) < 10:
            continue
        sxy_b = sum(w * v for w, v in grp)
        sxx_b = sum(w * w for w, _ in grp)
        k_b = sxy_b / sxx_b
        avg_v = sum(v for _, v in grp) / len(grp)
        print(f" {edge:3d}-{edge+10:3d}   {len(grp):4d}  {k_b:.6f}   {avg_v:5.1f} km/h")
    print("\n若各段 K 相近（相差 <5%）→ 线性良好，单系数可用；否则需要分段标定。")

    # ---- 4. 顺带：相电流 w7 与车速/电流的关系提示 ----
    print("\n=== 提示 ===")
    print("同一份日志里若含大电流段（current_a > 20），可用 w7 对相电流做非线性标定；")
    print("把日志发回即可继续分析。")


if __name__ == "__main__":
    main()
