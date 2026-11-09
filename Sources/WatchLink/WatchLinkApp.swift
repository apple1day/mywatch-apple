import SwiftUI

@main
struct WatchLinkApp: App {
    @StateObject private var monitor = BluetoothMonitor()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(monitor: monitor)
                .tint(WatchColors.accent)
                .onChange(of: scenePhase) { phase in
                    if phase == .background {
                        monitor.pauseForBackground()
                    }
                }
        }
    }
}
