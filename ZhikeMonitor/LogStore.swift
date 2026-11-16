import Foundation
import UIKit
import Combine

enum LogKind: String {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERR "
    case tx = "TX  "
    case rx = "RX  "
}

struct LogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let kind: LogKind
    let message: String

    var line: String {
        "\(LogTime.clock.string(from: time)) [\(kind.rawValue)] \(message)"
    }
}

/// 把 BLE 事件流与逐帧解码结果写入 Documents/ZhikeLogs/<会话>/ 下：
/// - events.log：可读事件流（连接、GATT 发现、TX/RX 原始字节、错误）
/// - frames.csv：每个校验通过的帧一行，含 32 个原始字与解码值
final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var files: [URL] = []
    @Published private(set) var bytesWritten = 0
    @Published private(set) var sessionStamp = ""
    @Published private(set) var folderPath = ""

    private let ioQueue = DispatchQueue(label: "com.zhike.monitor.log", qos: .utility)
    private var eventHandle: FileHandle?
    private var frameHandle: FileHandle?
    private var frameSeq = 0
    private var started = false
    private let maxEntries = 3000

    private init() {}

    var isRunning: Bool { started }

    // MARK: 会话

    func startSession() {
        guard !started else { return }
        started = true

        let stamp = LogTime.stamp.string(from: Date())
        sessionStamp = stamp

        let fileManager = FileManager.default
        let base = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("ZhikeLogs/\(stamp)", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        folderPath = folder.path

        let eventsURL = folder.appendingPathComponent("events.log")
        let framesURL = folder.appendingPathComponent("frames.csv")
        fileManager.createFile(atPath: eventsURL.path, contents: nil)
        fileManager.createFile(atPath: framesURL.path, contents: nil)

        eventHandle = try? FileHandle(forWritingTo: eventsURL)
        frameHandle = try? FileHandle(forWritingTo: framesURL)
        files = [framesURL, eventsURL]

        writeToFrames(ZhikeFrame.csvHeader)

        log(.info, "===== 会话开始 \(stamp) =====")
        log(.info, "App \(Bundle.main.appVersion) / iOS \(UIDevice.current.systemVersion) / \(UIDevice.current.model)")
        log(.info, "日志目录 \(folder.path)")
    }

    // MARK: 写入

    func log(_ kind: LogKind, _ message: String) {
        let entry = LogEntry(time: Date(), kind: kind, message: message)
        append(entry)
        writeToEvents(entry.line + "\n")
    }

    func logFrame(_ frame: ZhikeFrame) {
        frameSeq += 1
        writeToFrames(frame.csvRow(seq: frameSeq))
    }

    func clear() {
        entries.removeAll()
        bytesWritten = 0
        frameSeq = 0
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            if let handle = self.eventHandle { try? handle.truncate(atOffset: 0) }
            if let handle = self.frameHandle { try? handle.truncate(atOffset: 0) }
        }
        writeToFrames(ZhikeFrame.csvHeader)
        log(.info, "日志已清空")
    }

    // MARK: 内部

    private func append(_ entry: LogEntry) {
        if Thread.isMainThread {
            entries.append(entry)
            if entries.count > maxEntries {
                entries.removeFirst(entries.count - maxEntries)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.append(entry)
            }
        }
    }

    private func writeToEvents(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        ioQueue.async { [weak self] in
            guard let self = self, let handle = self.eventHandle else { return }
            do {
                try handle.write(contentsOf: data)
                self.bumpBytes(data.count)
            } catch {
                // 写盘失败时保留内存日志，避免递归记录
            }
        }
    }

    private func writeToFrames(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        ioQueue.async { [weak self] in
            guard let self = self, let handle = self.frameHandle else { return }
            do {
                try handle.write(contentsOf: data)
                self.bumpBytes(data.count)
            } catch {
            }
        }
    }

    private func bumpBytes(_ count: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.bytesWritten += count
        }
    }
}

extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version)(\(build))"
    }
}
