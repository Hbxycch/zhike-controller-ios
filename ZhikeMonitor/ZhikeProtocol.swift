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
// 依据 Motexa 2.7.0（com.motexaqixing.app）反编译基线：
//   [0..2]   帧头 AA 13 00
//   [3..64]  31 个小端 16 位数据字（word n 位于 3 + 2n），加上 [65..66] 校验字共 32 个字
//   [65..66] 校验字：sum(word0..word31) & 0xFFFF == 0xFFFF
//
// 字段（置信度见基线文档，未实车验证）：
//   w2  转把（原始值）
//   w6  转速：int16 / 5.46 → rpm
//   w8  母线电压：raw × 150 / 4096 → 0.1V
//   w9  母线电流：int16 → A
//   w18 控制器温度：raw / 100 → ℃（> 200℃ 视为无效）
//   w21 高字节=驾驶模式(1 有效)，bit4-5=挡位(1=高,2=低,其余=中)
//   w22 故障位图

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

    // MARK: 日志

    static let csvHeader: String = {
        let words = (0..<ZhikeFrame.wordCount).map { "w\($0)" }.joined(separator: ",")
        return "iso_time,seq,checksum_ok,hex,\(words),voltage_v,current_a,power_w,rpm,temp_c,gear,fault,throttle_raw\n"
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
        words[0] = 0x0002
        words[2] = throttle
        words[6] = UInt16(max(0, min(32000, Int((rpm * 5.46).rounded()))))
        words[8] = UInt16(max(0, min(65535, Int((voltage * 10.0 * 4096.0 / 150.0).rounded()))))
        words[9] = UInt16(bitPattern: Int16(clamping: Int(current.rounded())))
        words[18] = UInt16(max(0, min(20000, Int((temperature * 100).rounded()))))
        let gearBits = gear == 3 ? 1 : (gear == 1 ? 2 : 0)
        words[21] = UInt16(0x0100 | (gearBits << 4))
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
