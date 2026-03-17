import SwiftUI

struct RootView: View {
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
        .animation(.easeInOut(duration: 0.3), value: appState.route)
    }
}
