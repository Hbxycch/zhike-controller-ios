import SwiftUI
import UIKit

func formatBytes(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
    return String(format: "%.1f MB", Double(bytes) / 1024.0 / 1024.0)
}

/// 调起系统分享面板。文件已经复制成带时间戳的快照名，用户存到「文件」/微信后
/// 靠文件名就能区分是哪天、哪次导出的。
enum ShareSheet {
    static func present(_ items: [URL]) {
        guard !items.isEmpty else { return }
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else { return }

        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }

        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }
}

// MARK: - 原始帧

struct RawFramesView: View {
    @EnvironmentObject private var client: ZhikeBLEClient

    var body: some View {
        NavigationStack {
            List {
                if let frame = client.lastFrame {
                    Section {
                        WordGrid(words: frame.words, changed: client.changedWords)
                            .padding(.vertical, 6)
                    } header: {
                        Text("当前帧 32 个字（红色 = 相比上一帧发生变化）")
                    }

                    Section("当前帧 HEX（\(frame.bytes.count) 字节）") {
                        Text(frame.hex)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } else {
                    Section {
                        Text("尚未收到数据")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("最近帧（新 → 旧）") {
                    ForEach(client.recentFrames.reversed()) { frame in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(LogTime.clock.string(from: frame.timestamp))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(summary(frame))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(frame.hex)
                                .font(.system(size: 9, design: .monospaced))
                                .lineLimit(3)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("原始帧")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func summary(_ frame: ZhikeFrame) -> String {
        let voltage = frame.busVoltage.map { String(format: "%.1fV", $0) } ?? "--V"
        let rpm = frame.rpm.map { String(format: "%.0frpm", $0) } ?? "--rpm"
        return "\(voltage) \(String(format: "%.0fA", frame.busCurrent)) \(rpm)"
    }
}

struct WordGrid: View {
    let words: [UInt16]
    let changed: Set<Int>

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(0..<words.count, id: \.self) { index in
                let word = words[index]
                VStack(spacing: 2) {
                    Text("w\(index)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(String(word))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(changed.contains(index) ? Color.red.opacity(0.14) : Color(.tertiarySystemFill))
                )
                .foregroundStyle(changed.contains(index) ? Color.red : Color.primary)
            }
        }
    }
}

// MARK: - 日志

struct LogsView: View {
    @EnvironmentObject private var logs: LogStore
    @State private var paused = false
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sessionBar

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(logs.entries.suffix(800)) { entry in
                                Text(entry.line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(color(for: entry.kind))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(entry.id)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: logs.entries.count) { _ in
                        guard !paused, let last = logs.entries.last else { return }
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }

                footer
            }
            .navigationTitle("日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        ShareSheet.present(logs.exportCurrentSession())
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    NavigationLink {
                        SessionHistoryView()
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .confirmationDialog("清空今天的日志？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空 \(logs.sessionStamp)", role: .destructive) { logs.clearCurrentSession() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("只清空今天的 frames.csv 与 events.log，历史日期不受影响。清空前建议先导出。")
            }
        }
    }

    /// 顶部：今天的会话摘要 —— 明确告诉用户「数据在写、写到哪里、累计多少帧」
    private var sessionBar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle()
                    .fill(logs.lastWriteAt == nil ? Color.gray : Color.green)
                    .frame(width: 7, height: 7)
                Text("\(logs.sessionStamp)  ·  \(logs.totalFrames) 帧  ·  \(formatBytes(logs.bytesWritten))")
                    .font(.caption2.monospacedDigit())
                Spacer()
                if logs.resumedFromExisting {
                    Text("续写")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
            }
            Text(lastWriteText)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var lastWriteText: String {
        guard let last = logs.lastWriteAt else { return "等待数据…（每 5 秒落盘一次）" }
        let seconds = Int(Date().timeIntervalSince(last))
        return "最后写入 \(seconds) 秒前 · \(logs.folderPath)"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("内存 \(logs.entries.count) 条")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(isOn: $paused) {
                    Text("暂停滚动").font(.caption2)
                }
                .toggleStyle(.switch)
                .fixedSize()
            }
            Text("日志按天归档，同一天内重启 App 会继续追加到同一个文件，不会新建空会话。")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func color(for kind: LogKind) -> Color {
        switch kind {
        case .error: return .red
        case .warn: return .orange
        case .tx: return .blue
        case .rx: return .gray
        case .info: return .primary
        }
    }
}

// MARK: - 历史会话

struct SessionHistoryView: View {
    @EnvironmentObject private var logs: LogStore
    @State private var pendingDelete: LogSession?

    var body: some View {
        List {
            if logs.sessions.isEmpty {
                Text("还没有历史记录。连上控制器跑一段，日志会出现在这里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(logs.sessions) { session in
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(session.title)
                                    .font(.subheadline.weight(.semibold))
                                if session.isToday {
                                    Text("今天")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 4)
                                        .background(Color.green.opacity(0.18))
                                        .foregroundStyle(.green)
                                        .clipShape(Capsule())
                                }
                            }
                            Text("\(session.framesLabel) · \(formatBytes(session.bytes)) · 更新 \(LogTime.clock.string(from: session.modified))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            ShareSheet.present(logs.exportSession(session))
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .onDelete { indexSet in
                if let index = indexSet.first, logs.sessions.indices.contains(index) {
                    pendingDelete = logs.sessions[index]
                }
            }
        }
        .navigationTitle("历史会话")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { logs.refreshSessions() }
        .confirmationDialog(
            "删除 \(pendingDelete?.title ?? "") 的日志？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let session = pendingDelete { logs.deleteSession(session) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("frames.csv 与 events.log 会一起删除，无法恢复。建议先导出。")
        }
    }
}

// MARK: - 设备列表

struct DeviceListView: View {
    @EnvironmentObject private var client: ZhikeBLEClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("只显示 GEKOO / 智科设备", isOn: $client.filterZhikeOnly)
                    Button {
                        client.startScan()
                    } label: {
                        Label("重新扫描", systemImage: "arrow.clockwise")
                    }
                }

                Section("附近设备（\(client.devices.count)）") {
                    if client.devices.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在扫描…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(client.devices) { device in
                        Button {
                            client.connect(device)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .foregroundStyle(.primary)
                                    Text(device.id.uuidString)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(device.rssi) dBm")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择控制器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        client.startScan()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject private var client: ZhikeBLEClient
    @EnvironmentObject private var logs: LogStore
    @EnvironmentObject private var gps: GPSTracker

    @AppStorage("wheelCircumferenceMM") private var circumferenceMM: Double = 1529
    @AppStorage("gearRatio") private var gearRatio: Double = 5.8
    @AppStorage("speedFactorOverride") private var speedFactor: Double = 0.0155
    @State private var gpsSpeed: Double = 0
    @State private var referenceW6: Double = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("连接") {
                    Toggle("断线自动重连", isOn: $client.autoReconnect)
                    Toggle("只显示 GEKOO / 智科设备", isOn: $client.filterZhikeOnly)
                    Button("重新扫描") { client.startScan() }
                    Button("断开连接", role: .destructive) { client.disconnect() }
                }

                Section("车速换算") {
                    TextField("轮胎周长 (mm)", value: $circumferenceMM, format: .number)
                        .keyboardType(.decimalPad)
                    HStack {
                        Text("常用规格")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("130/70-12 · 1499") { circumferenceMM = 1499 }
                        Button("130/70-12 · 1529") { circumferenceMM = 1529 }
                    }
                    .buttonStyle(.bordered)
                    TextField("传动比（电机转 ÷ 车轮转）", value: $gearRatio, format: .number)
                        .keyboardType(.decimalPad)
                    Text("本车：130/70-12 轮胎（周长 1529mm，受压滚动约 1499mm），齿轮减速轮毂。\n2026-11-17 实车回归（904 帧 / GPS 690 帧）：等效传动比 ≈ 5.8，K = 0.0155 km/h 每 w6 单位，w6=5556 时约 86km/h，与满把 80~90km/h 一致。\n注意：控制器「极对数 16」是电角度参数，不参与机械减速，不能拿来算车速 —— 早前按 w6÷16 换算会把车速低估 2.7 倍。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("GPS（速度真值）") {
                    Toggle("记录 GPS 车速到日志", isOn: Binding(
                        get: { gps.isRunning },
                        set: { newValue in
                            if newValue { gps.requestPermission() } else { gps.stop() }
                        }
                    ))
                    HStack {
                        Text("授权")
                        Spacer()
                        Text(GPSTracker.describe(gps.status))
                            .foregroundStyle(gps.status == .authorizedWhenInUse || gps.status == .authorizedAlways
                                             ? Color.green : Color.orange)
                    }
                    .font(.subheadline)
                    if let v = gps.speedKmh {
                        HStack {
                            Text("当前车速")
                            Spacer()
                            Text(String(format: "%.1f km/h（精度 ±%.0fm）", v, gps.accuracyM))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                    Text("开启后，每帧 frames.csv 会写入 gps_kmh / gps_acc_m / gps_age_s / gps_valid。把日志发回来即可用回归解出车速系数 K，以及相电流标定。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("GPS 车速标定") {
                    HStack {
                        TextField("实测车速 (km/h)", value: $gpsSpeed, format: .number)
                            .keyboardType(.decimalPad)
                        Divider()
                        TextField("当时 w6", value: $referenceW6, format: .number)
                            .keyboardType(.numberPad)
                    }
                    HStack {
                        Button("计算并写入 K") {
                            if gpsSpeed > 0, referenceW6 > 0 {
                                speedFactor = gpsSpeed / referenceW6
                            }
                        }
                        .disabled(gpsSpeed <= 0 || referenceW6 <= 0)
                        Spacer()
                        Button("清除标定", role: .destructive) { speedFactor = 0 }
                            .disabled(speedFactor <= 0)
                    }
                    if speedFactor > 0 {
                        Text(String(format: "当前 K = %.6f km/h 每 w6 单位  →  w6=5556 时显示 %.1f km/h",
                                    speedFactor, speedFactor * 5556))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.blue)
                    } else {
                        Text(String(format: "未标定，按理论值 K = %.6f（传动比 %.2f, 周长 %.0fmm）",
                                    (circumferenceMM / 1000.0) * 0.06 / max(0.1, gearRatio),
                                    gearRatio, circumferenceMM))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text("标定方法：保持控车稳定（如满把巡航），记下仪表/GPS 的车速，同时看本 App「电机转速」的 w6 读数，两个数填进上面。K = 车速 ÷ w6，与传动比、周长无关，最可靠。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("演示") {
                    Toggle("演示模式（合成数据）", isOn: Binding(
                        get: { client.isDemo },
                        set: { newValue in
                            if newValue { client.startDemo() } else { client.stopDemo() }
                        }
                    ))
                    Text("没有控制器在身边时，可用合成数据检查界面与日志格式。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("日志") {
                    LabeledContent("今日会话", value: logs.sessionStamp)
                    LabeledContent("累计帧数", value: "\(logs.totalFrames)")
                    LabeledContent("已写入", value: formatBytes(logs.bytesWritten))
                    LabeledContent("模式", value: logs.resumedFromExisting ? "续写今天已有文件" : "新建文件")
                    if !logs.files.isEmpty {
                        Button("导出今天日志") {
                            ShareSheet.present(logs.exportCurrentSession())
                        }
                    }
                    NavigationLink("历史会话（按天归档）") {
                        SessionHistoryView()
                    }
                    Button("清空今天日志", role: .destructive) { logs.clearCurrentSession() }
                    Text("导出时会复制成 zhike-日期-时刻-frames.csv 这样的文件名，多次导出不会撞名。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(logs.folderPath)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Section("诊断信息") {
                    ForEach(client.characteristicInfo, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                    }
                    if client.characteristicInfo.isEmpty {
                        Text("连接后显示 GATT 服务与特征")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("关于") {
                    LabeledContent("版本", value: Bundle.main.appVersion)
                    Text("协议依据 Motexa 2.7.0 反编译基线实现，未经实车抓包验证。若数值出现 10 倍 / 100 倍偏差，请以日志中的原始帧（frames.csv 的 w0…w31）为准。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
