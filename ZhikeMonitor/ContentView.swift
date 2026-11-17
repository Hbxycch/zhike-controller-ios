import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var client: ZhikeBLEClient

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("监控", systemImage: "speedometer") }
            RawFramesView()
                .tabItem { Label("原始帧", systemImage: "square.grid.3x3.fill") }
            LogsView()
                .tabItem { Label("日志", systemImage: "doc.text") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .onAppear {
            LogStore.shared.startSession()
            client.autoReconnect = true
        }
    }
}

// MARK: - 监控面板

struct DashboardView: View {
    @EnvironmentObject private var client: ZhikeBLEClient
    @State private var showDevices = false

    private var frame: ZhikeFrame? { client.lastFrame }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    statusCard
                    metricsGrid
                    if let frame = frame {
                        faultCard(frame)
                        hexCard(frame)
                    }
                    infoCard
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("智科控制器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(client.isConnected ? "断开" : "连接") {
                        if client.isConnected {
                            client.disconnect()
                        } else {
                            showDevices = true
                            client.startScan()
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .sheet(isPresented: $showDevices) {
                DeviceListView()
                    .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: 状态卡

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(client.linkState.rawValue)
                    .font(.headline)
                Spacer()
                if client.frameRate > 0 {
                    Text("\(client.frameRate) 帧/秒")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                Text(client.connectedName.isEmpty ? "未选择设备" : client.connectedName)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                if client.rssi != 0 {
                    Text("\(client.rssi) dBm")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if !client.note.isEmpty {
                Text(client.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    showDevices = true
                    client.startScan()
                } label: {
                    Label("扫描设备", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    if client.isDemo {
                        client.stopDemo()
                    } else {
                        client.startDemo()
                    }
                } label: {
                    Label(client.isDemo ? "停止演示" : "演示模式", systemImage: "waveform.path")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .font(.subheadline)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var statusColor: Color {
        switch client.linkState {
        case .connected: return .green
        case .scanning, .connecting, .discovering: return .orange
        case .poweredOff, .unauthorized, .unsupported, .failed: return .red
        default: return .gray
        }
    }

    // MARK: 指标

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            MetricCard(title: "母线电压",
                       value: value { frame in frame.busVoltage.map { String(format: "%.1f", $0) } },
                       unit: "V")
            MetricCard(title: "母线电流",
                       value: value { frame in String(format: "%.0f", frame.busCurrent) },
                       unit: "A")
            MetricCard(title: "功率",
                       value: value { frame in frame.power.map { String(format: "%.0f", $0) } },
                       unit: "W")
            MetricCard(title: "电机转速",
                       value: value { frame in frame.rpm.map { String(format: "%.0f", $0) } },
                       unit: "rpm")
            MetricCard(title: "相电流(估)",
                       value: value { frame in frame.phaseCurrentEstimate.map { String(format: "%.1f", $0) } },
                       unit: "A")
            MetricCard(title: "控制器温度",
                       value: value { frame in frame.controllerTemp.map { String(format: "%.1f", $0) } },
                       unit: "℃")
            MetricCard(title: "转把电压",
                       value: value { frame in String(format: "%.2f", frame.throttleVoltage) },
                       unit: "V")
            MetricCard(title: "12V 电源",
                       value: value { frame in frame.twelveVoltRail.map { String(format: "%.2f", $0) } },
                       unit: "V")
            MetricCard(title: "控制量 w11",
                       value: value { frame in String(frame.ctrlWord) },
                       unit: "raw")
            MetricCard(title: "环境温度 w17",
                       value: value { frame in frame.auxTemp2.map { String(format: "%.1f", $0) } },
                       unit: "℃")
            MetricCard(title: "相电流采样 w14/w15",
                       value: value { frame in "\(frame.phaseSampleU) / \(frame.phaseSampleV)" },
                       unit: "raw")
            MetricCard(title: "负载量 w10 (iq?)",
                       value: value { frame in String(frame.loadAux2) },
                       unit: "raw")
            MetricCard(title: "状态 w20/w21",
                       value: value { frame in
                           let base = String(format: "%02X/%04X", frame.words[20], frame.words[21])
                           return frame.isRegenBraking ? base + " 回充" : base
                       },
                       unit: "")
            MetricCard(title: "故障码",
                       value: value { frame in String(format: "0x%04X", Int(frame.faultCode)) },
                       unit: "")
        }
    }

    private func value(_ transform: (ZhikeFrame) -> String?) -> String {
        guard let frame = frame else { return "--" }
        return transform(frame) ?? "--"
    }

    // MARK: 故障

    private func faultCard(_ frame: ZhikeFrame) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("故障位 w22 = \(String(format: "0x%04X", Int(frame.faultCode)))")
                .font(.caption)
                .foregroundStyle(.secondary)

            if frame.faultBits.isEmpty {
                Text("当前无故障位")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(frame.faultBits, id: \.self) { bit in
                            Text("bit\(bit)")
                                .font(.caption.monospacedDigit())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.red.opacity(0.12)))
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: 当前帧

    private func hexCard(_ frame: ZhikeFrame) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("当前帧 \(frame.bytes.count) 字节")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(frame.checksumValid ? "校验通过" : "校验失败")
                    .font(.caption)
                    .foregroundStyle(frame.checksumValid ? Color.green : Color.red)
            }
            Text(frame.hex)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: 链路信息

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("链路信息")
                .font(.caption)
                .foregroundStyle(.secondary)
            infoRow("已收帧数", "\(client.packetCount)")
            infoRow("校验失败", "\(client.checksumErrorCount)")
            infoRow("信号强度", client.rssi == 0 ? "--" : "\(client.rssi) dBm")
            infoRow("GATT 服务", "\(client.serviceInfo.count) 个")
            infoRow("订阅通知", "\(client.notifyCount) 个")
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .monospacedDigit()
        }
    }
}

// MARK: - 指标卡

struct MetricCard: View {
    let title: String
    let value: String
    let unit: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }
}
