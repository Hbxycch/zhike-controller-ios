import SwiftUI

func formatBytes(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
    return String(format: "%.1f MB", Double(bytes) / 1024.0 / 1024.0)
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
                    if !logs.files.isEmpty {
                        ShareLink(items: logs.files) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    Button(role: .destructive) {
                        logs.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("\(logs.entries.count) 条 · \(formatBytes(logs.bytesWritten))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(isOn: $paused) {
                    Text("暂停滚动").font(.caption2)
                }
                .toggleStyle(.switch)
                .fixedSize()
            }
            Text(logs.folderPath)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
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

    @AppStorage("wheelCircumferenceMM") private var circumferenceMM: Double = 1529
    @AppStorage("motorPolePairs") private var polePairs: Int = 16

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
                    Stepper(value: $polePairs, in: 1...64) {
                        Text("电机极对数 \(polePairs)")
                    }
                    Text("本车已确认：130/70-12 轮胎（理论周长 1529mm，受压滚动约 1499mm），极对数 16（官方「电机组」实读）。换算：车速 = w6 ÷ 16 × 周长 × 0.06。交叉验证：巡航峰值 w6=1398 → 8.0km/h，与官方 APP 表显一致。若与 GPS 比对恒定偏高约 2%，把周长改为 1499。")
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
                    LabeledContent("会话", value: logs.sessionStamp)
                    LabeledContent("已写入", value: formatBytes(logs.bytesWritten))
                    if !logs.files.isEmpty {
                        ShareLink(items: logs.files) {
                            Text("导出日志文件")
                        }
                    }
                    Button("清空日志", role: .destructive) { logs.clear() }
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
