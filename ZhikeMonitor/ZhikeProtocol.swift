import Foundation

// MARK: - 时间格式

enum LogTime {
    static let iso = make("yyyy-MM-dd'T'HH:mm:ss.SSS")
    static let clock = make("HH:mm:ss.SSS")
    static let stamp = make("yyyyMMdd-HHmmss")

    private static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = format
        return formatter
    }
}

extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02X", Int($0)) }.joined(separator: " ") }
}

// MARK: - 智科实时帧
//
// 帧结构（2026-11-16 实车 737 帧验证，校验 100% 通过）：
//   [0..2]   帧头 AA 13 00
//   [3..64]  31 个小端 16 位数据字（word n 位于 3 + 2n）
//   [65..66] 校验字 w31 = ~(w0+...+w30) & 0xFFFF，等价于 sum(w0..w31) & 0xFFFF == 0xFFFF
//
// 实车验证过的字段：
//   w0  恒 0x4163（消息类型/长度）
//   w2  转把 ADC：静止约 2100~2120，满把约 4800+
//   w6  转速：int16 / 5.46 → rpm（实测峰值 1398 → 256 rpm ≈ 23km/h，符合国标限速；
//       lag-1 自相关 0.974，起步平滑爬升，静止为 0，倒推为小幅负值）
//   w8  母线电压：raw × 150 / 4096 → 0.1V（实测 81.1~82.4V，72V 满电合理）
//   w9  母线电流：int16 → A（实测 0~43A，滑行/回充为负，与电压相关系数 -0.92）
//   w18 控制器温度：raw / 100 → ℃（实测随负载 19.45 → 19.99℃ 缓慢上升）
//   w31 校验字
//
// 实车候选字段（语义基本确认，标定系数待受控实验）：
//   w11 PWM 占空比：0~4096（起步低转速大转矩时接近满量程，符合占空比行为）
//   w14 / w15 相电流瞬时采样（int16，两路几乎同步，包络与母线电流正相关；
//       属异步采样，单帧数值在 ±峰值内跳动，不能按线性标定）
//   w7  与负载强相关的平滑量（疑似相电流有效值或转矩电流，系数未定）
//   w10 与母线电流相关 0.82 的平滑量（疑似 iq / 相电流滤波值，系数未定）
//   w13 小幅噪声 ±350（疑似 id / 偏置）
//   w16 / 100 ≈ 31℃（恒定，疑似 MOS 或第二温度点）
//   w17 / 100 ≈ 21℃（恒定，疑似环境温度）
//   w20 / w21 状态位图（骑行时 w20=3；w21 取值 2/10/58/258/266）
//   w1 ≈ w3 ≈ w15 × 1.16（疑似与 w15 同源的采样/换算）
//   w4 静止时恒 0xAAAA，骑行时全幅跳动（疑似载波/PWM 计数器异步采样）
//   w23 429~509 慢变，瞬间跳变（非温度，语义未知）

struct ZhikeFrame: Identifiable {
    static let header: [UInt8] = [0xAA, 0x13, 0x00]
    static let shortResponse: [UInt8] = [0xAA, 0x13, 0x00, 0x01]
    static let frameLength = 67
    static let wordCount = 32

    let id = UUID()
    let timestamp: Date
    let bytes: [UInt8]
    let words: [UInt16]

    init?(bytes: [UInt8], timestamp: Date = Date()) {
        guard bytes.count >= ZhikeFrame.frameLength else { return nil }
        let frame = Array(bytes.prefix(ZhikeFrame.frameLength))
        var parsed: [UInt16] = []
        parsed.reserveCapacity(ZhikeFrame.wordCount)
        var offset = ZhikeFrame.header.count
        while offset + 1 < ZhikeFrame.frameLength {
            parsed.append(UInt16(frame[offset]) | (UInt16(frame[offset + 1]) << 8))
            offset += 2
        }
        guard parsed.count == ZhikeFrame.wordCount else { return nil }
        self.timestamp = timestamp
        self.bytes = frame
        self.words = parsed
    }

    var checksumValid: Bool {
        var sum = 0
        for word in words { sum = (sum + Int(word)) & 0xFFFF }
        return sum == 0xFFFF
    }

    var hex: String { bytes.hexString }

    var wordHex: String { words.map { String(format: "%04X", Int($0)) }.joined(separator: " ") }

    // MARK: 解码字段

    var throttleRaw: UInt16 { words[2] }

    var rpm: Double? {
        let raw = Int16(bitPattern: words[6])
        guard raw > 0 else { return nil }
        return Double(raw) / 5.46
    }

    var busVoltage: Double? {
        let deciVolt = Double(words[8]) * 150.0 / 4096.0
        guard deciVolt > 1.0 else { return nil }
        return deciVolt / 10.0
    }

    var busCurrent: Double { Double(Int16(bitPattern: words[9])) }

    var power: Double? {
        guard let voltage = busVoltage else { return nil }
        return voltage * busCurrent
    }

    var controllerTemp: Double? {
        let raw = words[18]
        guard raw > 0, raw <= 20000 else { return nil }
        return Double(raw) / 100.0
    }

    var gear: Int? {
        let state = words[21]
        guard ((state >> 8) & 0xFF) == 1 else { return nil }
        switch (state >> 4) & 0x03 {
        case 1: return 3
        case 2: return 1
        default: return 2
        }
    }

    var faultCode: UInt16 { words[22] }

    var faultBits: [Int] {
        (0..<16).filter { (Int(faultCode) >> $0) & 1 == 1 }
    }

    // MARK: 实车验证新增字段

    /// PWM 占空比 w11（0~4096 → %）
    var dutyCycle: Double? {
        let raw = words[11]
        guard raw > 0, raw <= 4300 else { return nil }
        return Double(raw) / 4096.0 * 100.0
    }

    /// 相电流瞬时采样 U（int16 原始值，异步采样）
    var phaseSampleU: Int16 { Int16(bitPattern: words[14]) }

    /// 相电流瞬时采样 V（int16 原始值，与 U 几乎同步）
    var phaseSampleV: Int16 { Int16(bitPattern: words[15]) }

    /// 与负载强相关的平滑量 w7（疑似相电流有效值，系数未定）
    var loadAux1: Int16 { Int16(bitPattern: words[7]) }

    /// 与母线电流相关 0.82 的平滑量 w10（疑似 iq，系数未定）
    var loadAux2: Int16 { Int16(bitPattern: words[10]) }

    /// w16/100 ≈ 31℃ 恒定（疑似 MOS 温度）
    var auxTemp1: Double? {
        let raw = words[16]
        guard raw > 0, raw <= 20000 else { return nil }
        return Double(raw) / 100.0
    }

    /// w17/100 ≈ 21℃ 恒定（疑似环境温度）
    var auxTemp2: Double? {
        let raw = words[17]
        guard raw > 0, raw <= 20000 else { return nil }
        return Double(raw) / 100.0
    }

    /// 状态位图 w20 / w21
    var statusWord: UInt32 { (UInt32(words[21]) << 16) | UInt32(words[20]) }

    // MARK: 日志

    static let csvHeader: String = {
        let words = (0..<ZhikeFrame.wordCount).map { "w\($0)" }.joined(separator: ",")
        return "iso_time,seq,checksum_ok,hex,\(words),voltage_v,current_a,power_w,rpm,temp_c,gear,fault,throttle_raw,duty_pct,phase_u_raw,phase_v_raw,load_aux_w7,load_aux_w10,aux_temp1_w16,aux_temp2_w17\n"
    }()

    func csvRow(seq: Int) -> String {
        var fields: [String] = []
        fields.append(LogTime.iso.string(from: timestamp))
        fields.append(String(seq))
        fields.append(checksumValid ? "1" : "0")
        fields.append(hex)
        fields.append(contentsOf: words.map { String($0) })
        fields.append(busVoltage.map { String(format: "%.2f", $0) } ?? "")
        fields.append(String(format: "%.1f", busCurrent))
        fields.append(power.map { String(format: "%.1f", $0) } ?? "")
        fields.append(rpm.map { String(format: "%.1f", $0) } ?? "")
        fields.append(controllerTemp.map { String(format: "%.2f", $0) } ?? "")
        fields.append(gear.map { String($0) } ?? "")
        fields.append(String(format: "0x%04X", Int(faultCode)))
        fields.append(String(throttleRaw))
        fields.append(dutyCycle.map { String(format: "%.1f", $0) } ?? "")
        fields.append(String(phaseSampleU))
        fields.append(String(phaseSampleV))
        fields.append(String(loadAux1))
        fields.append(String(loadAux2))
        fields.append(auxTemp1.map { String(format: "%.2f", $0) } ?? "")
        fields.append(auxTemp2.map { String(format: "%.2f", $0) } ?? "")
        return fields.joined(separator: ",") + "\n"
    }
}

// MARK: - 拆包 / 重同步

final class ZhikeFrameAssembler {
    private var buffer: [UInt8] = []
    private let bufferLimit = 4096

    func reset() {
        buffer.removeAll()
    }

    func append(_ data: [UInt8]) -> [ZhikeFrame] {
        guard !data.isEmpty else { return [] }
        buffer.append(contentsOf: data)
        if buffer.count > bufferLimit {
            buffer.removeFirst(buffer.count - bufferLimit)
        }

        var frames: [ZhikeFrame] = []
        var cursor = 0

        while cursor < buffer.count {
            guard let headerIndex = firstHeader(from: cursor) else {
                cursor = max(cursor, buffer.count - 2)
                break
            }
            cursor = headerIndex

            let available = buffer.count - cursor

            if available >= ZhikeFrame.frameLength {
                let candidate = Array(buffer[cursor..<(cursor + ZhikeFrame.frameLength)])
                if let frame = ZhikeFrame(bytes: candidate), frame.checksumValid {
                    frames.append(frame)
                    cursor += ZhikeFrame.frameLength
                    continue
                }
            }

            if available >= ZhikeFrame.shortResponse.count,
               Array(buffer[cursor..<(cursor + ZhikeFrame.shortResponse.count)]) == ZhikeFrame.shortResponse {
                let next = cursor + ZhikeFrame.shortResponse.count
                if available == ZhikeFrame.shortResponse.count || startsWithHeader(at: next) {
                    cursor = next
                    continue
                }
            }

            if available >= ZhikeFrame.frameLength {
                cursor += 1
                continue
            }

            break
        }

        if cursor >= buffer.count {
            buffer.removeAll()
        } else if cursor > 0 {
            buffer.removeFirst(cursor)
        }

        return frames
    }

    private func firstHeader(from start: Int) -> Int? {
        guard buffer.count >= ZhikeFrame.header.count else { return nil }
        var index = max(0, start)
        while index + ZhikeFrame.header.count <= buffer.count {
            if buffer[index] == 0xAA, buffer[index + 1] == 0x13, buffer[index + 2] == 0x00 {
                return index
            }
            index += 1
        }
        return nil
    }

    private func startsWithHeader(at index: Int) -> Bool {
        guard index + ZhikeFrame.header.count <= buffer.count else { return false }
        return buffer[index] == 0xAA && buffer[index + 1] == 0x13 && buffer[index + 2] == 0x00
    }
}

// MARK: - 演示数据（仅用于无硬件时验证界面与日志）

enum ZhikeDemo {
    static func frame(rpm: Double,
                      voltage: Double,
                      current: Double,
                      temperature: Double,
                      gear: Int,
                      throttle: UInt16,
                      fault: UInt16) -> [UInt8] {
        var words = [UInt16](repeating: 0, count: ZhikeFrame.wordCount)
        words[0] = 0x4163
        words[2] = throttle
        words[6] = UInt16(bitPattern: Int16(max(0, min(1400, Int((rpm * 5.46).rounded())))))
        words[8] = UInt16(max(0, min(65535, Int((voltage * 10.0 * 4096.0 / 150.0).rounded()))))
        words[9] = UInt16(bitPattern: Int16(clamping: Int(current.rounded())))
        words[11] = UInt16(max(0, min(4096, Int(abs(current) / 50.0 * 4096.0))))
        words[14] = UInt16(bitPattern: Int16(clamping: Int(current * 138.0 * Double.random(in: 0.2...1.0))))
        words[15] = words[14]
        words[7] = UInt16(bitPattern: Int16(clamping: Int(abs(current) * 120.0)))
        words[10] = UInt16(bitPattern: Int16(clamping: Int(abs(current) * 96.0)))
        words[16] = 3104
        words[17] = 2101
        words[18] = UInt16(max(0, min(20000, Int((temperature * 100).rounded()))))
        words[20] = current != 0 ? 3 : 0
        words[21] = 58
        words[22] = fault

        var sum = 0
        for index in 0..<(ZhikeFrame.wordCount - 1) {
            sum = (sum + Int(words[index])) & 0xFFFF
        }
        words[ZhikeFrame.wordCount - 1] = UInt16((0xFFFF - sum) & 0xFFFF)

        var bytes = ZhikeFrame.header
        for word in words {
            bytes.append(UInt8(word & 0x00FF))
            bytes.append(UInt8((word >> 8) & 0x00FF))
        }
        return bytes
    }
}
