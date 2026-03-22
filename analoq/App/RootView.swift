import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch appState.route {
            case .launching:
                LaunchView()

            case .login:
                LoginView(
                    viewModel: LoginViewModel(auth: appState.auth)
                ) { token in
                    Task { await appState.didLogin(token: token) }
                }

            case .serverSelection:
                ServerSelectionView(
                    vm: appState.serverStore!
                ) { server in
                    Task { await appState.didSelectServer(server) }
                }

            case .librarySelection:
                if let libraryStore = appState.libraryStore {
                    LibrarySelectionView(
                        store: libraryStore
                    ) {
                        Task { await appState.didSelectLibraries() }
                    }
                } else {
                    LaunchView()
                }

            case .main:
                if let channelStore = appState.channelStore, let player = appState.player {
                    MainView()
                        .environmentObject(channelStore)
                        .environmentObject(player)
                } else {
                    LaunchView()
                }
            }
        }
        .task { await appState.boot() }
        .onChange(of: scenePhase) { _, phase in
            Task { await handleScenePhaseChange(phase) }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.route)
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) async {
        guard let player = appState.player else { return }

        switch phase {
        case .active:
            await player.resumeAfterLifecycleSuspendIfNeeded()
        case .inactive, .background:
            player.suspendForLifecycle()
        @unknown default:
            player.suspendForLifecycle()
        }
    }
}
