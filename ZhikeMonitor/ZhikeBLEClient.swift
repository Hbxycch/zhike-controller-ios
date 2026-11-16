import Foundation
import CoreBluetooth
import Combine

enum LinkState: String {
    case unknown = "等待蓝牙"
    case poweredOff = "蓝牙已关闭"
    case unauthorized = "未授权蓝牙"
    case unsupported = "设备不支持"
    case idle = "未连接"
    case scanning = "扫描中"
    case connecting = "连接中"
    case discovering = "读取服务"
    case connected = "已连接"
    case failed = "连接失败"
}

struct BLEDevice: Identifiable, Hashable {
    let id: UUID
    let name: String
    let rssi: Int
}

final class ZhikeBLEClient: NSObject, ObservableObject {

    // 链路状态
    @Published private(set) var linkState: LinkState = .unknown
    @Published private(set) var devices: [BLEDevice] = []
    @Published private(set) var connectedName = ""
    @Published private(set) var note = ""

    // 数据
    @Published private(set) var lastFrame: ZhikeFrame?
    @Published private(set) var recentFrames: [ZhikeFrame] = []
    @Published private(set) var changedWords: Set<Int> = []
    @Published private(set) var packetCount = 0
    @Published private(set) var checksumErrorCount = 0
    @Published private(set) var frameRate = 0
    @Published private(set) var rssi = 0

    // 诊断
    @Published private(set) var serviceInfo: [String] = []
    @Published private(set) var characteristicInfo: [String] = []
    @Published private(set) var notifyCount = 0
    @Published private(set) var isDemo = false

    // 设置项
    @Published var filterZhikeOnly = false {
        didSet { if isScanning { restartScan() } }
    }
    @Published var autoReconnect = true

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var discovered: [UUID: CBPeripheral] = [:]
    private var writeCharacteristic: CBCharacteristic?
    private var initCharacteristic: CBCharacteristic?
    private var notifyCharacteristics: [CBCharacteristic] = []

    private let assembler = ZhikeFrameAssembler()
    private let logs = LogStore.shared

    private var pollTimer: Timer?
    private var rateTimer: Timer?
    private var demoTimer: Timer?
    private var packetsInSecond = 0
    private var isScanning = false
    private var sessionStarted = false
    private var shouldAutoReconnect = false
    private var demoPhase: Double = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var isConnected: Bool { linkState == .connected }

    // MARK: - 扫描

    func startScan() {
        guard central.state == .poweredOn else {
            note = "蓝牙不可用，请检查系统蓝牙与权限"
            return
        }
        guard !isScanning else { return }

        devices.removeAll()
        discovered.removeAll()
        isScanning = true
        linkState = .scanning
        note = ""
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        logs.log(.info, "开始扫描（只显示智科设备：\(filterZhikeOnly ? "是" : "否")）")

        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self = self, self.isScanning else { return }
            self.stopScan()
            if self.linkState == .scanning { self.linkState = .idle }
        }
    }

    func stopScan() {
        if central.state == .poweredOn { central.stopScan() }
        isScanning = false
        if linkState == .scanning { linkState = .idle }
    }

    private func restartScan() {
        stopScan()
        startScan()
    }

    // MARK: - 连接

    func connect(_ device: BLEDevice) {
        guard let target = discovered[device.id] else {
            note = "设备信息已过期，请重新扫描"
            return
        }
        stopScan()
        stopSession()
        resetSessionData()

        peripheral = target
        target.delegate = self
        connectedName = device.name
        linkState = .connecting
        shouldAutoReconnect = true
        note = ""

        logs.log(.info, "开始连接 \(device.name) (\(device.id.uuidString))")
        central.connect(target, options: nil)
    }

    func disconnect() {
        shouldAutoReconnect = false
        stopSession()
        if let peripheral = peripheral {
            central.cancelPeripheralConnection(peripheral)
            logs.log(.info, "主动断开 \(connectedName)")
        }
        peripheral = nil
        connectedName = ""
        linkState = .idle
        note = ""
        rssi = 0
    }

    private func stopSession() {
        pollTimer?.invalidate()
        pollTimer = nil
        rateTimer?.invalidate()
        rateTimer = nil
        demoTimer?.invalidate()
        demoTimer = nil
        sessionStarted = false
        assembler.reset()
        writeCharacteristic = nil
        initCharacteristic = nil
        notifyCharacteristics.removeAll()
        notifyCount = 0
    }

    // MARK: - 命令

    private func sendInit() {
        let frame: [UInt8] = [0x01, 0x02]
        if let target = initCharacteristic ?? writeCharacteristic {
            write(frame, to: target)
        } else {
            logs.log(.warn, "未找到可写特征，开启帧未发送")
        }
    }

    private func sendPoll() {
        guard let target = writeCharacteristic else { return }
        write([0xAA, 0x13, 0xFF, 0x01, 0xAA, 0x13, 0x00, 0x01], to: target)
    }

    private func write(_ bytes: [UInt8], to characteristic: CBCharacteristic) {
        guard let peripheral = peripheral, peripheral.state == .connected else { return }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(Data(bytes), for: characteristic, type: type)
        logs.log(.tx, "\(characteristic.uuid.uuidString) \(bytes.hexString)")
    }

    private func beginSessionIfReady() {
        guard !sessionStarted, writeCharacteristic != nil, !notifyCharacteristics.isEmpty else { return }
        sessionStarted = true
        linkState = .connected
        notifyCount = notifyCharacteristics.count
        logs.log(.info, "链路就绪：写特征=\(writeCharacteristic?.uuid.uuidString ?? "-")，订阅通知 \(notifyCharacteristics.count) 个")

        sendInit()

        // 给控制器 300ms 处理开启帧，再开始 200ms 轮询
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.sessionStarted, self.pollTimer == nil else { return }
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.sendPoll()
            }
        }

        rateTimer?.invalidate()
        rateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.frameRate = self.packetsInSecond
            self.packetsInSecond = 0
            if let peripheral = self.peripheral, peripheral.state == .connected {
                peripheral.readRSSI()
            }
        }
    }

    private func resetSessionData() {
        packetCount = 0
        checksumErrorCount = 0
        frameRate = 0
        packetsInSecond = 0
        recentFrames.removeAll()
        lastFrame = nil
        changedWords = []
        serviceInfo = []
        characteristicInfo = []
        rssi = 0
    }

    // MARK: - 帧处理

    private func handle(_ frame: ZhikeFrame) {
        guard frame.checksumValid else {
            checksumErrorCount += 1
            logs.log(.error, "帧校验失败 \(frame.hex)")
            return
        }

        packetsInSecond += 1
        packetCount += 1
        changedWords = diff(previous: lastFrame, current: frame)
        lastFrame = frame

        recentFrames.append(frame)
        if recentFrames.count > 400 {
            recentFrames.removeFirst(recentFrames.count - 400)
        }

        logs.logFrame(frame)
    }

    private func diff(previous: ZhikeFrame?, current: ZhikeFrame) -> Set<Int> {
        guard let previous = previous else { return [] }
        var result = Set<Int>()
        let count = min(previous.words.count, current.words.count)
        for index in 0..<count where previous.words[index] != current.words[index] {
            result.insert(index)
        }
        return result
    }

    // MARK: - 演示模式

    func startDemo() {
        guard !isDemo else { return }
        isDemo = true
        if peripheral != nil { disconnect() }
        stopSession()
        resetSessionData()

        sessionStarted = true
        linkState = .connected
        connectedName = "演示模式（合成数据）"
        demoPhase = 0
        logs.log(.info, "进入演示模式，数据为合成值，仅用于验证界面与日志格式")

        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.demoPhase += 0.2
            let t = self.demoPhase
            let rpm = 2400 + 900 * sin(t / 3.0)
            let voltage = 71.5 + 0.8 * sin(t / 7.0)
            let current = 18 + 14 * sin(t / 2.0) + 4 * sin(t * 1.7)
            let temperature = 34 + 6 * sin(t / 9.0)
            let throttle = UInt16(max(0, min(4095, Int(800 + 1800 * (0.5 + 0.5 * sin(t / 2.0))))))
            let bytes = ZhikeDemo.frame(rpm: rpm,
                                        voltage: voltage,
                                        current: current,
                                        temperature: temperature,
                                        gear: 2,
                                        throttle: throttle,
                                        fault: 0)
            if let frame = ZhikeFrame(bytes: bytes) { self.handle(frame) }
        }

        rateTimer?.invalidate()
        rateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.frameRate = self.packetsInSecond
            self.packetsInSecond = 0
        }
    }

    func stopDemo() {
        isDemo = false
        stopSession()
        linkState = .idle
        connectedName = ""
        note = ""
        rssi = 0
        logs.log(.info, "退出演示模式")
    }

    // MARK: - 工具

    private func describe(_ properties: CBCharacteristicProperties) -> String {
        var items: [String] = []
        if properties.contains(.read) { items.append("read") }
        if properties.contains(.write) { items.append("write") }
        if properties.contains(.writeWithoutResponse) { items.append("writeNR") }
        if properties.contains(.notify) { items.append("notify") }
        if properties.contains(.indicate) { items.append("indicate") }
        return items.isEmpty ? "none" : items.joined(separator: "|")
    }
}

// MARK: - CBCentralManagerDelegate

extension ZhikeBLEClient: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            logs.log(.info, "蓝牙就绪")
            if linkState == .unknown || linkState == .poweredOff || linkState == .unauthorized || linkState == .unsupported {
                linkState = .idle
            }
        case .poweredOff:
            linkState = .poweredOff
            note = "请打开系统蓝牙"
            logs.log(.warn, "蓝牙已关闭")
            stopSession()
        case .unauthorized:
            linkState = .unauthorized
            note = "请在 设置 → 隐私与安全性 → 蓝牙 中允许本 App 使用蓝牙"
            logs.log(.error, "蓝牙未授权")
        case .unsupported:
            linkState = .unsupported
            note = "当前设备不支持蓝牙"
            logs.log(.error, "设备不支持蓝牙")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advName ?? "未命名设备"

        if filterZhikeOnly {
            let upper = name.uppercased()
            guard upper.contains("GEKOO") || upper.contains("ZHIKE") || upper.contains("智科") else { return }
        }

        discovered[peripheral.identifier] = peripheral

        let rssiValue = RSSI.intValue == 127 ? -100 : RSSI.intValue
        let device = BLEDevice(id: peripheral.identifier, name: name, rssi: rssiValue)
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
            logs.log(.info, "发现设备 \(name) RSSI=\(rssiValue)")
        }
        devices.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logs.log(.info, "已连接 \(peripheral.name ?? "设备")，开始发现服务")
        linkState = .discovering
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logs.log(.error, "连接失败：\(error?.localizedDescription ?? "未知原因")")
        linkState = .failed
        note = "连接失败，请重试"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logs.log(.warn, "连接断开：\(error?.localizedDescription ?? "正常断开")")
        // 演示模式与 BLE 无关，忽略这次回调，避免把演示定时器一起停掉
        if isDemo { return }

        stopSession()
        rssi = 0
        linkState = .idle
        guard autoReconnect, shouldAutoReconnect else {
            note = "连接已断开"
            return
        }
        note = "连接断开，2 秒后自动重连…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, self.shouldAutoReconnect, let peripheral = self.peripheral else { return }
            self.linkState = .connecting
            self.central.connect(peripheral, options: nil)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension ZhikeBLEClient: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            logs.log(.error, "发现服务失败：\(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        serviceInfo = services.map { $0.uuid.uuidString }
        logs.log(.info, "发现服务 \(services.count) 个：\(serviceInfo.joined(separator: ", "))")
        guard !services.isEmpty else {
            note = "该设备没有可用的 GATT 服务"
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            logs.log(.error, "发现特征失败：\(error.localizedDescription)")
            return
        }

        for characteristic in service.characteristics ?? [] {
            let properties = describe(characteristic.properties)
            let line = "\(service.uuid.uuidString)/\(characteristic.uuid.uuidString) [\(properties)]"
            if !characteristicInfo.contains(line) { characteristicInfo.append(line) }
            logs.log(.info, "特征 \(line)")

            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                if !notifyCharacteristics.contains(where: { $0.uuid == characteristic.uuid }) {
                    notifyCharacteristics.append(characteristic)
                }
                peripheral.setNotifyValue(true, for: characteristic)
            }

            if characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                let uuid = characteristic.uuid.uuidString.uppercased()
                if uuid.contains("FFE2") {
                    initCharacteristic = characteristic
                } else if uuid.contains("FFE1") {
                    writeCharacteristic = characteristic
                } else if writeCharacteristic == nil {
                    writeCharacteristic = characteristic
                }
            }
        }

        beginSessionIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logs.log(.error, "通知回调错误：\(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value, !data.isEmpty else { return }

        let bytes = [UInt8](data)
        logs.log(.rx, "\(characteristic.uuid.uuidString) \(bytes.hexString)")

        let frames = assembler.append(bytes)
        for frame in frames {
            handle(frame)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logs.log(.error, "写入失败 \(characteristic.uuid.uuidString)：\(error.localizedDescription)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if error == nil {
            rssi = RSSI.intValue
        }
    }
}
