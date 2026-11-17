import Foundation
import Combine
import CoreLocation

/// 采集 iPhone 的 GPS 瞬时速度，并与蓝牙帧时间戳对齐。
///
/// 目的：frames.csv 里每一帧都带上当时的速度真值，事后可直接对 w6 做回归，
/// 解出「km/h 每 w6 单位」的标定系数 K = 车速 ÷ w6，不再依赖仪表或手抄。
///
/// 注意：
/// - loc.speed < 0 表示该定位点没有有效速度（静止/信号差），记为无效，不参与标定
/// - 采样率约 1Hz，帧率 5Hz，所以按「最近时间戳」对齐，容差默认 2 秒
final class GPSTracker: NSObject, ObservableObject {
    static let shared = GPSTracker()

    @Published private(set) var speedKmh: Double?
    @Published private(set) var accuracyM: Double = -1
    @Published private(set) var updatedAt: Date?
    @Published private(set) var status: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isRunning = false
    @Published private(set) var sampleCount = 0
    @Published private(set) var validCount = 0

    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var recent: [(date: Date, kmh: Double, acc: Double, valid: Bool)] = []

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        status = manager.authorizationStatus
    }

    // MARK: 控制

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
        isRunning = true
        LogStore.shared.log(.info, "GPS 采集启动（授权 \(Self.describe(status))）")
    }

    func stop() {
        manager.stopUpdatingLocation()
        isRunning = false
        LogStore.shared.log(.info, "GPS 采集停止")
    }

    /// 未授权时启动会直接弹系统授权框
    func requestPermission() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            start()
        }
    }

    // MARK: 取样本

    /// 取与给定帧时间最近的 GPS 样本；超出容差或速度无效则返回 nil
    func sample(near date: Date, tolerance: TimeInterval = 2.0)
        -> (kmh: Double, acc: Double, age: Double, valid: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        guard let best = recent.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }) else { return nil }
        let age = abs(best.date.timeIntervalSince(date))
        guard age <= tolerance else { return nil }
        return (best.kmh, best.acc, age, best.valid)
    }

    func clearSamples() {
        lock.lock()
        recent.removeAll()
        lock.unlock()
        sampleCount = 0
        validCount = 0
    }

    static func describe(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .authorizedAlways: return "始终允许"
        case .authorizedWhenInUse: return "使用期间"
        case .denied: return "已拒绝"
        case .restricted: return "受限"
        case .notDetermined: return "未询问"
        @unknown default: return "未知"
        }
    }
}

extension GPSTracker: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        DispatchQueue.main.async { self.status = s }
        LogStore.shared.log(.info, "GPS 授权变更：\(Self.describe(s))")
        if s == .authorizedWhenInUse || s == .authorizedAlways {
            manager.startUpdatingLocation()
            DispatchQueue.main.async { self.isRunning = true }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        // speed 为 -1 时表示无有效速度读数
        let valid = loc.speed >= 0
        let kmh = valid ? loc.speed * 3.6 : 0
        let acc = loc.horizontalAccuracy

        lock.lock()
        recent.append((loc.timestamp, kmh, acc, valid))
        if recent.count > 30 { recent.removeFirst(recent.count - 30) }
        lock.unlock()

        DispatchQueue.main.async {
            self.speedKmh = kmh
            self.accuracyM = acc
            self.updatedAt = loc.timestamp
            self.sampleCount += 1
            if valid { self.validCount += 1 }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        LogStore.shared.log(.warn, "GPS 错误：\(error.localizedDescription)")
    }
}
