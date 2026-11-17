import SwiftUI

/// 外观模式：跟随系统 / 浅色 / 深色
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    static let storageKey = "appearance"
}

@main
struct ZhikeMonitorApp: App {
    @StateObject private var client = ZhikeBLEClient()
    @ObservedObject private var logs = LogStore.shared
    @ObservedObject private var gps = GPSTracker.shared
    @AppStorage(Appearance.storageKey) private var appearanceRaw = Appearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
                .environmentObject(logs)
                .environmentObject(gps)
                .preferredColorScheme(Appearance(rawValue: appearanceRaw)?.colorScheme)
        }
    }
}
