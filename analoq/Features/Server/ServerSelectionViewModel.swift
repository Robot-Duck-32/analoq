import Foundation

@MainActor
class ServerSelectionViewModel: ObservableObject {

    enum State { case loading, loaded([AnaloqServer]), empty, error(String) }

    @Published var state: State = .loading
    @Published var selectedServer: AnaloqServer?

    private let discovery: ServerDiscoveryService

    init(discovery: ServerDiscoveryService) { self.discovery = discovery }

    func load() async {
        state = .loading
        do {
            let servers = try await discovery.discoverServers()
            if servers.isEmpty { state = .empty; return }
            state = .loaded(servers)
            if servers.count == 1, servers[0].isReachable { select(servers[0]) }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func select(_ server: AnaloqServer) {
        guard let connection = server.preferredConnection else { return }
        selectedServer = server
        UserDefaults.standard.set(connection.uri, forKey: "selectedServerURL")
        UserDefaults.standard.set(server.id,      forKey: "selectedServerID")
        UserDefaults.standard.set(server.name,    forKey: "selectedServerName")
    }
}
