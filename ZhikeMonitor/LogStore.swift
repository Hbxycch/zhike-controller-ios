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

/// 磁盘上的一次会话（按天一个目录：Documents/ZhikeLogs/yyyyMMdd/）
struct LogSession: Identifiable, Hashable {
    let id: String          // 目录名
    let folder: URL
    let framesURL: URL
    let eventsURL: URL
    let frames: Int
    let bytes: Int
    let modified: Date
    let isToday: Bool

    var title: String {
        // 20261117 → 2026-11-17
        guard id.count == 8 else { return id }
        let y = id.prefix(4), m = id.dropFirst(4).prefix(2), d = id.suffix(2)
        return "\(y)-\(m)-\(d)"
    }

    var framesLabel: String { "\(frames) 帧" }
}

/// 把 BLE 事件流与逐帧解码结果写入 Documents/ZhikeLogs/<yyyyMMdd>/ 下：
/// - events.log：可读事件流（连接、GATT 发现、TX/RX 原始字节、错误）
/// - frames.csv：每个校验通过的帧一行，含 32 个原始字与解码值
///
/// 关键设计（2026-11-17 修订，解决「跑一圈回来日志消失」）：
/// 1. **同一天内始终续写同一个文件**。冷启动/被系统回收后重启，会以追加方式
///    打开当天的 frames.csv 与 events.log，序号接着上次继续，不再新建空会话。
/// 2. 打开文件后立刻 seekToEnd，避免 FileHandle 默认偏移 0 导致从头覆盖旧数据。
/// 3. 每 5 秒 fsync 一次，进后台 / 退出前强制 fsync，减少进程被杀时尾部丢失。
/// 4. 保留历史会话列表，日志页可查看、导出、删除任意一天的数据。
final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var files: [URL] = []
    @Published private(set) var bytesWritten = 0
    @Published private(set) var sessionStamp = ""
    @Published private(set) var folderPath = ""
    @Published private(set) var totalFrames = 0
    @Published private(set) var lastWriteAt: Date?
    @Published private(set) var resumedFromExisting = false
    @Published private(set) var sessions: [LogSession] = []
    @Published private(set) var loggingEnabled = true

    private let ioQueue = DispatchQueue(label: "com.zhike.monitor.log", qos: .utility)
    private let ioKey = DispatchSpecificKey<Bool>()
    private var eventHandle: FileHandle?
    private var frameHandle: FileHandle?
    private var framesURL: URL?
    private var eventsURL: URL?
    private var frameSeq = 0
    private var started = false
    private var flushTimer: Timer?
    private var byteTotal = 0
    private var lastPublish = Date.distantPast
    private var lastByteStamp = Date.distantPast
    private let maxEntries = 3000
    static let loggingEnabledKey = "loggingEnabled"

    private init() {
        UserDefaults.standard.register(defaults: [Self.loggingEnabledKey: true])
        loggingEnabled = UserDefaults.standard.object(forKey: Self.loggingEnabledKey) as? Bool ?? true
        ioQueue.setSpecific(key: ioKey, value: true)
        observeAppLifecycle()
    }

    var isRunning: Bool { started }

    /// 写盘总开关：关闭后 UI 事件流继续显示，但不再写 frames.csv / events.log。
    /// 状态变更先记日志再改标志，保证 events.log 里有记录。
    func setLoggingEnabled(_ on: Bool) {
        guard on != loggingEnabled else { return }
        if on {
            loggingEnabled = true
            UserDefaults.standard.set(true, forKey: Self.loggingEnabledKey)
            // 若暂停期间 frames.csv 还是空的（表头没写过），补上
            if let url = framesURL, fileSize(url) == 0 {
                writeToFrames(ZhikeFrame.csvHeader)
            }
            log(.info, "===== 日志记录已开启 =====")
        } else {
            log(.info, "===== 日志记录已暂停（屏幕仍显示，写盘停止）=====")
            loggingEnabled = false
            UserDefaults.standard.set(false, forKey: Self.loggingEnabledKey)
            flushNow()
        }
    }

    // MARK: - 会话

    func startSession() {
        guard !started else { return }
        started = true

        let day = LogTime.day.string(from: Date())
        sessionStamp = day

        let fileManager = FileManager.default
        let base = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZhikeLogs", isDirectory: true)
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)

        let folder = base.appendingPathComponent(day, isDirectory: true)
        resumedFromExisting = fileManager.fileExists(atPath: folder.path)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        folderPath = folder.path

        let events = folder.appendingPathComponent("events.log")
        let frames = folder.appendingPathComponent("frames.csv")
        eventsURL = events
        framesURL = frames
        files = [frames, events]

        // 表头只在首次创建时写入
        if !fileManager.fileExists(atPath: frames.path) {
            fileManager.createFile(atPath: frames.path, contents: nil)
        }
        if !fileManager.fileExists(atPath: events.path) {
            fileManager.createFile(atPath: events.path, contents: nil)
        }

        eventHandle = openForAppend(events)
        frameHandle = openForAppend(frames)

        let existingFrames = max(0, countLines(frames) - 1)
        frameSeq = existingFrames
        totalFrames = existingFrames
        bytesWritten = fileSize(frames) + fileSize(events)
        byteTotal = bytesWritten

        if existingFrames == 0 && loggingEnabled {
            writeToFrames(ZhikeFrame.csvHeader)
        }

        log(.info, "===== 会话\(resumedFromExisting ? "续写" : "开始") \(day) =====")
        log(.info, "App \(Bundle.main.appVersion) / iOS \(UIDevice.current.systemVersion) / \(UIDevice.current.model)")
        log(.info, "日志目录 \(folder.path)")
        if existingFrames > 0 {
            log(.info, "已恢复今天的历史记录：\(existingFrames) 帧，后面接着追加")
        }

        startFlushTimer()
        refreshSessions()
    }

    func refreshSessions() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let list = Self.scanSessions()
            DispatchQueue.main.async { self.sessions = list }
        }
    }

    /// 删除某一天的全部日志（当前会话日期会先关闭文件再重建）
    func deleteSession(_ session: LogSession) {
        if session.id == sessionStamp {
            clearCurrentSession()
            return
        }
        ioQueue.async { [weak self] in
            try? FileManager.default.removeItem(at: session.folder)
            guard let self = self else { return }
            let list = Self.scanSessions()
            DispatchQueue.main.async {
                self.sessions = list
                self.log(.info, "已删除历史会话 \(session.id)")
            }
        }
    }

    // MARK: - 导出

    /// 导出今天的日志：先复制成带时间戳的快照，再交给系统分享。
    /// 文件名形如 zhike-20261117-221218-frames.csv，两次导出不会撞名。
    func exportCurrentSession() -> [URL] {
        flushNow()
        guard let frames = framesURL, let events = eventsURL else { return [] }
        return makeSnapshot(frames: frames, events: events, day: sessionStamp)
    }

    /// 导出某一天的历史会话
    func exportSession(_ session: LogSession) -> [URL] {
        makeSnapshot(frames: session.framesURL, events: session.eventsURL, day: session.id)
    }

    /// 把日志复制到临时目录并重命名；同一秒内重复导出自动加序号
    private func makeSnapshot(frames: URL, events: URL, day: String) -> [URL] {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent("ZhikeExport", isDirectory: true)
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)

        let stamp = LogTime.hms.string(from: Date())
        var result: [URL] = []

        for (source, kind) in [(frames, "frames.csv"), (events, "events.log")] {
            guard fileManager.fileExists(atPath: source.path) else { continue }
            var name = "zhike-\(day)-\(stamp)-\(kind)"
            var destination = base.appendingPathComponent(name)
            var index = 2
            while fileManager.fileExists(atPath: destination.path) {
                name = "zhike-\(day)-\(stamp)-\(index)-\(kind)"
                destination = base.appendingPathComponent(name)
                index += 1
            }
            do {
                try fileManager.copyItem(at: source, to: destination)
                result.append(destination)
            } catch {
                log(.warn, "导出失败 \(kind)：\(error.localizedDescription)")
            }
        }

        cleanupExports(keeping: 6)
        if !result.isEmpty {
            log(.info, "导出快照 \(result.map { $0.lastPathComponent }.joined(separator: ", "))")
        }
        return result
    }

    /// 只保留最近几次快照，避免临时目录越堆越大
    private func cleanupExports(keeping limit: Int) {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent("ZhikeExport", isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: base.path) else { return }
        let sorted = names.sorted(by: >)
        for name in sorted.dropFirst(limit) {
            try? fileManager.removeItem(at: base.appendingPathComponent(name))
        }
    }

    // MARK: - 写入

    func log(_ kind: LogKind, _ message: String) {
        let entry = LogEntry(time: Date(), kind: kind, message: message)
        append(entry)
        writeToEvents(entry.line + "\n")
    }

    func logFrame(_ frame: ZhikeFrame) {
        guard loggingEnabled else { return }
        frameSeq += 1
        let seq = frameSeq
        writeToFrames(frame.csvRow(seq: seq))
        // 节流：UI 每秒刷新一次帧计数，避免 5Hz 重绘整页
        let now = Date()
        if now.timeIntervalSince(lastPublish) >= 1.0 {
            lastPublish = now
            DispatchQueue.main.async { [weak self] in self?.totalFrames = seq }
        }
    }

    /// 清空当前会话：安全地关闭句柄 → 删除 → 重新建文件 → 写表头
    func clearCurrentSession() {
        stopFlushTimer()
        onIOSync {
            try? self.eventHandle?.synchronize()
            try? self.frameHandle?.synchronize()
            try? self.eventHandle?.close()
            try? self.frameHandle?.close()
            self.eventHandle = nil
            self.frameHandle = nil
        }

        let fileManager = FileManager.default
        if let url = framesURL { try? fileManager.removeItem(at: url) }
        if let url = eventsURL { try? fileManager.removeItem(at: url) }

        let folder = URL(fileURLWithPath: folderPath)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        if let url = framesURL {
            fileManager.createFile(atPath: url.path, contents: nil)
            frameHandle = openForAppend(url)
        }
        if let url = eventsURL {
            fileManager.createFile(atPath: url.path, contents: nil)
            eventHandle = openForAppend(url)
        }

        entries.removeAll()
        bytesWritten = 0
        byteTotal = 0
        frameSeq = 0
        totalFrames = 0
        resumedFromExisting = false

        writeToFrames(ZhikeFrame.csvHeader)
        startFlushTimer()
        log(.info, "日志已清空（\(sessionStamp)），续写同一文件")
        refreshSessions()
    }

    /// 兼容旧调用名
    func clear() { clearCurrentSession() }

    // MARK: - 落盘

    func flush() {
        onIO {
            try? self.eventHandle?.synchronize()
            try? self.frameHandle?.synchronize()
        }
    }

    /// 同步落盘，用于进后台 / 即将退出
    func flushNow() {
        onIOSync {
            try? self.eventHandle?.synchronize()
            try? self.frameHandle?.synchronize()
        }
    }

    private func startFlushTimer() {
        stopFlushTimer()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.flush()
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    private func stopFlushTimer() {
        flushTimer?.invalidate()
        flushTimer = nil
    }

    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                           object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.log(.info, "App 进入后台，强制落盘（蓝牙后台模式继续采集）")
            self.flushNow()
        }
        center.addObserver(forName: UIApplication.willTerminateNotification,
                           object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.log(.info, "===== App 即将退出 =====")
            self.flushNow()
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.refreshSessions()
        }
    }

    // MARK: - 内部

    private func onIO(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: ioKey) != nil {
            block()
        } else {
            ioQueue.async(execute: block)
        }
    }

    private func onIOSync(_ block: () -> Void) {
        if DispatchQueue.getSpecific(key: ioKey) != nil {
            block()
        } else {
            ioQueue.sync(execute: block)
        }
    }

    /// 以追加方式打开；文件不存在则创建。打开后强制 seek 到末尾。
    private func openForAppend(_ url: URL) -> FileHandle? {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        handle.seekToEndOfFile()
        // 上次若在行中间被杀，补一个换行，避免新行接在残行后面
        ensureTrailingNewline(url)
        handle.seekToEndOfFile()
        return handle
    }

    private func ensureTrailingNewline(_ url: URL) {
        guard let reader = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? reader.close() }
        let size = (try? reader.seekToEnd()) ?? 0
        guard size > 0 else { return }
        try? reader.seek(toOffset: size - 1)
        guard let data = try? reader.read(upToCount: 1), let last = data.first else { return }
        if last != 0x0A {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                if let nl = "\n".data(using: .utf8) { try? handle.write(contentsOf: nl) }
                try? handle.close()
            }
        }
    }

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
        onIO { [weak self] in
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
        onIO { [weak self] in
            guard let self = self, let handle = self.frameHandle else { return }
            do {
                try handle.write(contentsOf: data)
                self.bumpBytes(data.count)
            } catch {
            }
        }
    }

    private func bumpBytes(_ count: Int) {
        let now = Date()
        let shouldPublish = now.timeIntervalSince(lastByteStamp) >= 1.0
        if shouldPublish { lastByteStamp = now }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.byteTotal += count
            if shouldPublish {
                self.bytesWritten = self.byteTotal
                self.lastWriteAt = now
            }
        }
    }

    private func fileSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func countLines(_ url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        var count = 0
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            for byte in chunk where byte == 0x0A { count += 1 }
        }
        return count
    }

    // MARK: - 目录扫描

    private static func scanSessions() -> [LogSession] {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZhikeLogs", isDirectory: true)
        let today = LogTime.day.string(from: Date())

        guard let names = try? fileManager.contentsOfDirectory(atPath: base.path) else { return [] }

        var result: [LogSession] = []
        for name in names {
            let folder = base.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let frames = folder.appendingPathComponent("frames.csv")
            let events = folder.appendingPathComponent("events.log")
            let attrs = try? fileManager.attributesOfItem(atPath: frames.path)
            let modified = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
            let framesSize = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            let eventsAttrs = try? fileManager.attributesOfItem(atPath: events.path)
            let eventsSize = (eventsAttrs?[.size] as? NSNumber)?.intValue ?? 0

            var lines = 0
            if let handle = try? FileHandle(forReadingFrom: frames) {
                defer { try? handle.close() }
                while true {
                    let chunk = handle.readData(ofLength: 1 << 20)
                    if chunk.isEmpty { break }
                    for byte in chunk where byte == 0x0A { lines += 1 }
                }
            }

            result.append(LogSession(
                id: name,
                folder: folder,
                framesURL: frames,
                eventsURL: events,
                frames: max(0, lines - 1),
                bytes: framesSize + eventsSize,
                modified: modified,
                isToday: name == today
            ))
        }

        return result.sorted { $0.id > $1.id }
    }
}

extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version)(\(build))"
    }
}
