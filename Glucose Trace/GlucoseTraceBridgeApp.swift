import SwiftUI

@main
struct GlucoseTraceBridgeApp: App {
    @StateObject private var bridge: GlucoseBridgeManager

    // StateObject creates its object lazily, perhaps not at all in a
    // background launch. iOS relaunches the app for Bluetooth state
    // restoration, and the manager must exist then, so it is made here.
    init() {
        let manager = GlucoseBridgeManager()
        _bridge = StateObject(wrappedValue: manager)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bridge)
        }
    }
}
