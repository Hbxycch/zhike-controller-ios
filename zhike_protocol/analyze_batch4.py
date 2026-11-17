"""第四批实车日志分析：GPS 车速 ↔ w6 转速回归，解 K（km/h per w6 unit）。

用法：
    python analyze_batch4.py "frames 2(1).csv"

第四批日志特点：App 1.0(1) 版本，904 帧，GPS 有效 690 帧，最高 58 km/h。
结论（2026-11-17 运行）：
    - w6 是 int16，滑行/回充时出现 65533（= -3）等负值
    - 只在「有电流驱动」时 w6 与车速才线性相关：松开转把后齿轮/离合器解耦，w6 掉到 0
      （因此不能拿滑行样本做标定，会严重低估 K）
"""
import csv
import sys
import math
import statistics as st
from datetime import datetime


def load(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for r in csv.DictReader(f):
            if r.get("checksum_ok") != "1":
                continue
            raw = int(r["w6"])
            w6 = raw - 65536 if raw >= 32768 else raw
            gps = float(r["gps_kmh"]) if r["gps_kmh"] else None
            rows.append({
                "t": datetime.fromisoformat(r["iso_time"]),
                "w6": w6,
                "gps": gps,
                "acc": float(r["gps_acc_m"]) if r["gps_acc_m"] else -1,
                "cur": float(r["current_a"]),
                "volt": float(r["voltage_v"]),
                "temp": float(r["temp_c"]) if r["temp_c"] else None,
                "valid": r["gps_valid"] == "1",
            })
    return rows


def corr(xs, ys):
    n = len(xs)
    if n < 3:
        return 0.0
    mx, my = sum(xs) / n, sum(ys) / n
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    sxx = sum((x - mx) ** 2 for x in xs)
    syy = sum((y - my) ** 2 for y in ys)
    if sxx <= 0 or syy <= 0:
        return 0.0
    return sxy / math.sqrt(sxx * syy)


def main(path):
    rows = load(path)
    print(f"帧数 {len(rows)}  时间 {rows[0]['t']:%H:%M:%S} → {rows[-1]['t']:%H:%M:%S}")
    dur = (rows[-1]["t"] - rows[0]["t"]).total_seconds()
    print(f"时长 {dur:.1f}s  平均帧率 {len(rows) / dur:.2f} Hz")

    # 1) 滞后扫描：看 w6 与 GPS 速度在哪个时间偏移下最相关
    print("\n[滞后扫描] 偏移(帧) 偏移(s) 样本 相关系数")
    best = (None, -1.0)
    for lag in range(-6, 7):
        xs, ys = [], []
        for i in range(len(rows)):
            j = i + lag
            if 0 <= j < len(rows):
                r = rows[j]
                if r["gps"] is not None and r["valid"] and r["w6"] > 0 and r["gps"] > 3 and r["acc"] <= 12:
                    xs.append(r["w6"])
                    ys.append(r["gps"])
        c = corr(xs, ys)
        if c > best[1]:
            best = (lag, c)
        print(f"  {lag:+3d}   {lag * 0.3:+.1f}   {len(xs):4d}   {c:.4f}")
    print(f"最佳偏移 {best[0]} 帧 ({best[0] * 0.3:+.1f}s)，r={best[1]:.4f}")

    # 2) 标定样本：必须有驱动电流、速度够高、精度够好
    def samples(lag=0, cur_min=3.0, spd_min=10.0, acc_max=12.0):
        out = []
        for i in range(len(rows)):
            j = i + lag
            if not (0 <= j < len(rows)):
                continue
            r = rows[j]
            if r["gps"] is None or not r["valid"] or r["w6"] <= 0:
                continue
            if r["cur"] < cur_min or r["gps"] < spd_min or r["acc"] > acc_max:
                continue
            out.append(r)
        return out

    for cur_min in (0.0, 3.0, 10.0):
        s = samples(lag=best[0], cur_min=cur_min)
        if len(s) < 5:
            print(f"\n[标定] 电流>{cur_min}A 样本不足 ({len(s)})")
            continue
        num = sum(r["gps"] * r["w6"] for r in s)
        den = sum(r["w6"] * r["w6"] for r in s)
        k = num / den
        ss_res = sum((r["gps"] - k * r["w6"]) ** 2 for r in s)
        mean_g = sum(r["gps"] for r in s) / len(s)
        ss_tot = sum((r["gps"] - mean_g) ** 2 for r in s)
        r2 = 1 - ss_res / ss_tot if ss_tot > 0 else 0
        err = [r["gps"] - k * r["w6"] for r in s]
        print(f"\n[标定] 电流>{cur_min}A  样本 {len(s)}  K={k:.6f} km/h per w6  R²={r2:.4f}"
              f"  残差 σ={st.pstdev(err):.2f} km/h")
        print(f"       反推：w6=3000 → {k * 3000:.1f} km/h   w6=5556 → {k * 5556:.1f} km/h")

    # 3) 高速段逐帧核对
    fast = [r for r in rows if r["gps"] and r["valid"] and r["gps"] >= 45]
    if fast:
        print(f"\n[高速段] ≥45km/h 共 {len(fast)} 帧")
        for r in fast[:10]:
            print(f"  {r['t']:%H:%M:%S.%f}"[:12], f"w6={r['w6']:5d} gps={r['gps']:5.1f} I={r['cur']:6.1f} V={r['volt']:.1f}")

    # 4) 电流/转速一致性
    drive = [r for r in rows if r["cur"] > 5 and r["w6"] > 500]
    if drive:
        print(f"\n[驱动段] {len(drive)} 帧  w6 中位 {st.median([r['w6'] for r in drive]):.0f}"
              f"  电流中位 {st.median([r['cur'] for r in drive]):.1f}A"
              f"  最高 w6 {max(r['w6'] for r in drive)}")
    zero_w6 = sum(1 for r in rows if r["w6"] <= 0)
    print(f"w6≤0 的帧 {zero_w6} ({zero_w6 / len(rows) * 100:.0f}%)：滑行/回充/静止，不可用于标定")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "frames 2(1).csv")
