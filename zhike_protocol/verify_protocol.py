"""按 ZhikeProtocol.swift 的算法做编解码闭环验证。"""

HEADER = bytes([0xAA, 0x13, 0x00])


def build(rpm, voltage, current, temp, gear, throttle, fault):
    words = [0] * 32
    words[0] = 0x0002
    words[2] = throttle
    words[6] = max(0, min(32000, round(rpm * 5.46)))
    words[8] = max(0, min(65535, round(voltage * 10.0 * 4096.0 / 150.0)))
    words[9] = round(current) & 0xFFFF
    words[18] = max(0, min(20000, round(temp * 100)))
    gear_bits = 1 if gear == 3 else (2 if gear == 1 else 0)
    words[21] = 0x0100 | (gear_bits << 4)
    words[22] = fault
    total = 0
    for w in words[:31]:
        total = (total + w) & 0xFFFF
    words[31] = (0xFFFF - total) & 0xFFFF
    out = bytearray(HEADER)
    for w in words:
        out.append(w & 0xFF)
        out.append((w >> 8) & 0xFF)
    return bytes(out)


def parse(frame):
    assert len(frame) == 67, len(frame)
    words = []
    off = 3
    while off + 1 < 67:
        words.append(frame[off] | (frame[off + 1] << 8))
        off += 2
    assert len(words) == 32, len(words)
    ok = sum(words[:32]) & 0xFFFF == 0xFFFF
    raw_rpm = words[6] if words[6] < 0x8000 else words[6] - 0x10000
    deci_v = words[8] * 150.0 / 4096.0
    cur = words[9] if words[9] < 0x8000 else words[9] - 0x10000
    return {
        "checksum_ok": ok,
        "rpm": round(raw_rpm / 5.46, 1) if raw_rpm > 0 else None,
        "voltage": round(deci_v / 10.0, 2) if deci_v > 1 else None,
        "current": cur,
        "power": round(deci_v / 10.0 * cur, 1),
        "temp": round(words[18] / 100.0, 2) if 0 < words[18] <= 20000 else None,
        "gear_bits": (words[21] >> 4) & 0x03,
        "mode": (words[21] >> 8) & 0xFF,
        "fault": hex(words[22]),
        "throttle": words[2],
    }


cases = [
    dict(rpm=3200, voltage=72.0, current=35, temp=42.5, gear=2, throttle=1500, fault=0),
    dict(rpm=6100, voltage=84.3, current=118, temp=88.2, gear=3, throttle=3800, fault=0x0004),
    dict(rpm=0, voltage=48.2, current=0, temp=25.0, gear=1, throttle=0, fault=0),
]

for c in cases:
    f = build(**c)
    p = parse(f)
    print("输入:", c)
    print("帧长:", len(f), "帧头:", f[:3].hex(" ").upper())
    print("解析:", p)
    print("-" * 60)

# 拆包测试：模拟字节流被任意切分
stream = b"".join(build(**c) for c in cases)
print("拼接流长度:", len(stream))
