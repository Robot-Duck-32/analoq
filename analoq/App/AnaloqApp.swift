import SwiftUI

@main
struct AnaloqApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                #if os(iOS)
                .statusBarHidden(true)
                #endif
        }
    }
}
