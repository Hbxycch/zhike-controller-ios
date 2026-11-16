import SwiftUI

@main
struct ZhikeMonitorApp: App {
    @StateObject private var client = ZhikeBLEClient()
    @ObservedObject private var logs = LogStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
                .environmentObject(logs)
        }
    }
}
