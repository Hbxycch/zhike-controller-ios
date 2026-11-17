import Foundation

// MARK: - 时间格式

enum LogTime {
    static let iso = make("yyyy-MM-dd'T'HH:mm:ss.SSS")
    static let clock = make("HH:mm:ss.SSS")
    static let stamp = make("yyyyMMdd-HHmmss")
    /// 会话目录名：按天归档，同一天的所有启动都续写同一份文件
    static let day = make("yyyyMMdd")
    /// 导出快照的时刻后缀：HHmmss
    static let hms = make("HHmmss")

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
// 实车验证过的字段（2026-11-16 深夜用官方"蓝牙助手"APP 截图真值二次标定，车型 CP72850）：
//   w0  恒 0x4163（消息类型/长度）
//   w2  转把：ADC 原始值；电压 = w2 × 0.0004096 V（官方 0.86/1.27/1.39V 三点线性吻合）
//   w6  电机转速 = w6 直接读数，rpm（官方 999/1016.48rpm 与 w6=988~1017 对应；
//       8km/h↔999rpm 与峰值 1398↔11km/h 线性一致。注意：不要除 5.46，那是 Motexa 系的换算）
//   w8  母线电压：raw × 150 / 4096 → 0.1V（实测 81.1~82.4V，72V 满电合理）
//   w9  母线电流：int16 → A（实测 0~43A，滑行/回充为负，与电压相关系数 -0.92）
//   w16 12V 电源电压 = w16 × 19/4096（官方恒显 14.41V ↔ w16≈3104）
//   w17 疑似环境温度 = w17/100（恒 ~21.0℃）
//   w18 控制器温度：raw / 100 → ℃（官方 18.58℃ 显示格式精确吻合）
//   w31 校验字
//
// 相电流标定（⚠️ 第 3 批数据发现工况依赖，系数不可靠）：
//   相电流(A) ≈ w7 × 0.0045 —— 仅在官方截图同款"稳态巡航"工况下成立
//   （官方 4.35A↔w7=968）。但第 3 批满油门加速段（母线 48A）w7 仅 1636，
//   斜率从 ~250/字 掉到 ~21/字 → w7 标度随工况非线性，可能是 iq 经增益调度。
//   w7 符号与转矩方向一致：驱动为正、回充为负。
//   w14/w15 是相电流瞬时采样（异步，包络∝负载），w10 疑似 iq，w13 疑似 id/偏置。
//   w11 控制量（第 3 批修正）：0~12571，与转速相关 0.981、与电流仅 0.713，
//   疑似速度环输出/PWM 调制指令，不是占空比，不能按 4096 满量程换算。
//   w20 / w21 状态位图（官方端口状态：高刹等）：
//     w21 bit1 = 高刹（官方"高刹=1"）
//     w21 bit8 = 回充/再生制动标志（第 3 批：松把滑行母线 -12A 时同步置位）
//     w21 bit10 偶发，语义未定
//   w4 静止时恒 0xAAAA，骑行时全幅跳动（疑似载波/PWM 计数器异步采样）
//   w23 429~509 慢变，瞬间跳变（非温度，语义未知）
//   转速实测量程：静止 0 ↔ 满油门 5556rpm（若按 1017rpm↔8km/h 折算约 43.7km/h）

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

    /// 转把电压 = w2 × 0.0004096 V（官方 APP 三点真值线性标定）
    var throttleVoltage: Double { Double(words[2]) * 0.0004096 }

    /// 电机转速 = w6 直接读数 rpm（官方 APP 真值确认，不要除 5.46）
    var rpm: Double? {
        let raw = Int16(bitPattern: words[6])
        guard raw > 0 else { return nil }
        return Double(raw)
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

    /// 12V 电源电压 = w16 × 19/4096（官方恒显 14.41V ↔ w16≈3104）
    var twelveVoltRail: Double? {
        let raw = words[16]
        guard raw > 0 else { return nil }
        return Double(raw) * 19.0 / 4096.0
    }

    /// 相电流估计值 ≈ w7 × 0.0045 A —— 仅稳态巡航工况近似成立，加速/回充段不可用
    var phaseCurrentEstimate: Double? {
        let raw = Double(Int16(bitPattern: words[7]))
        guard raw > 0 else { return nil }
        return raw * 0.0045
    }

    /// w7 原始值：转矩电流量纲（驱动为正、回充为负），标度随工况非线性
    var torqueCurrentRaw: Int16 { Int16(bitPattern: words[7]) }

    /// 控制量 w11 原始值（疑似速度环输出/PWM 调制指令，实测 0~12571，与转速相关 0.98）
    var ctrlWord: UInt16 { words[11] }

    /// 回充/再生制动标志：w21 bit8（松把滑行母线电流为负时同步置位）
    var isRegenBraking: Bool { (words[21] >> 8) & 1 == 1 }

    /// 相电流瞬时采样 U（int16 原始值，异步采样）
    var phaseSampleU: Int16 { Int16(bitPattern: words[14]) }

    /// 相电流瞬时采样 V（int16 原始值，与 U 几乎同步）
    var phaseSampleV: Int16 { Int16(bitPattern: words[15]) }

    /// 与负载强相关的平滑量 w7（相电流有效值的原始计数，×0.0045 ≈ A）
    var loadAux1: Int16 { Int16(bitPattern: words[7]) }

    /// 与母线电流相关 0.82 的平滑量 w10（疑似 iq，系数未定）
    var loadAux2: Int16 { Int16(bitPattern: words[10]) }

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
        return "iso_time,seq,checksum_ok,hex,\(words),voltage_v,current_a,power_w,rpm,temp_c,gear,fault,throttle_raw,ctrl_w11,phase_u_raw,phase_v_raw,phase_a_est,throttle_v,twelve_v_w16,aux_temp_w17,regen,gps_kmh,gps_acc_m,gps_age_s,gps_valid\n"
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
        fields.append(String(ctrlWord))
        fields.append(String(phaseSampleU))
        fields.append(String(phaseSampleV))
        fields.append(phaseCurrentEstimate.map { String(format: "%.2f", $0) } ?? "")
        fields.append(String(format: "%.3f", throttleVoltage))
        fields.append(twelveVoltRail.map { String(format: "%.2f", $0) } ?? "")
        fields.append(auxTemp2.map { String(format: "%.2f", $0) } ?? "")
        fields.append(isRegenBraking ? "1" : "0")

        // GPS 速度真值：按时间戳就近对齐（±2s），供事后回归求车速系数 K
        if let gps = GPSTracker.shared.sample(near: timestamp) {
            fields.append(gps.valid ? String(format: "%.2f", gps.kmh) : "")
            fields.append(String(format: "%.1f", gps.acc))
            fields.append(String(format: "%.2f", gps.age))
            fields.append(gps.valid ? "1" : "0")
        } else {
            fields.append("")
            fields.append("")
            fields.append("")
            fields.append("0")
        }
        return fields.joined(separator: ",") + "\n"
    }
}

// MARK: - 车速换算（需人工标定：轮胎周长 + 电机极对数）
//
// w6 经实车数据验证为电机电转速（不是轮速）：
//   按 12 寸 130/70 周长 1.529m 计，若当轮速用，5556rpm 会得出 510km/h，物理不成立。
//   因此轮速 = w6 ÷ 极对数，车速 = 轮速 × 周长 × 0.06。
// 参考：12 寸常规极对数 28（10 寸 23，瓦片 16），以控制器「电机组-极对数」实际值为准。

enum SpeedCalibration {
    static let circumferenceKey = "wheelCircumferenceMM"
    static let polePairsKey = "motorPolePairs"
    /// 直接标定的车速系数 K（km/h 每 w6 单位）。0 = 未标定，按 极对数×周长 理论计算。
    static let factorKey = "speedFactorOverride"
}

extension ZhikeFrame {
    /// 理论车速 km/h = (w6 ÷ 极对数) × 周长(m) × 0.06
    func theoreticalSpeed(circumferenceMM: Double, polePairs: Int) -> Double? {
        guard let rpm = rpm, polePairs > 0, circumferenceMM > 0 else { return nil }
        let wheelRPM = rpm / Double(polePairs)
        return wheelRPM * (circumferenceMM / 1000.0) * 0.06
    }

    /// 实际展示用车速：优先用实测标定系数 K，未标定时回退到理论换算
    func speed(circumferenceMM: Double, polePairs: Int, factorOverride: Double) -> Double? {
        if factorOverride > 0, let rpm = rpm { return rpm * factorOverride }
        return theoreticalSpeed(circumferenceMM: circumferenceMM, polePairs: polePairs)
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
        words[6] = UInt16(bitPattern: Int16(clamping: Int(rpm.rounded())))
        words[8] = UInt16(max(0, min(65535, Int((voltage * 10.0 * 4096.0 / 150.0).rounded()))))
        words[9] = UInt16(bitPattern: Int16(clamping: Int(current.rounded())))
        words[11] = UInt16(clamping: Int(rpm * 2.2))
        let torqueRaw = Int(current < 0 ? current * 55.0 : current * 24.0 + (current > 0 ? 400 : 0))
        words[7] = UInt16(bitPattern: Int16(clamping: torqueRaw))
        words[10] = UInt16(bitPattern: Int16(clamping: Int(abs(current) * 96.0)))
        let phaseA = abs(current) * 1.3
        words[14] = UInt16(bitPattern: Int16(clamping: Int((phaseA / 0.0045) * Double.random(in: 0.2...1.0))))
        words[15] = words[14]
        words[16] = 3104
        words[17] = 2101
        words[18] = UInt16(max(0, min(20000, Int((temperature * 100).rounded()))))
        words[20] = current != 0 ? 3 : 0
        words[21] = current < 0 ? 258 : (current != 0 ? 2 : 2)
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
