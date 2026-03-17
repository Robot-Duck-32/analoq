import Foundation

@MainActor
final class AppState: ObservableObject {

    // MARK: – Navigation
    @Published var route: AppRoute = .launching

    enum AppRoute: Equatable {
        case launching
        case login
        case serverSelection
        case librarySelection
        case main
    }

    // MARK: – Services
    let auth = AnaloqAuthService()

    private(set) var serverDiscovery:    ServerDiscoveryService?
    private(set) var libraryService:     LibraryService?
    private(set) var collectionService:  CollectionService?
    private(set) var streamService:      StreamService?

    // MARK: – Stores & Player
    private(set) var serverStore:    ServerSelectionViewModel?
    private(set) var libraryStore:   LibrarySelectionStore?
    private(set) var channelStore:   ChannelStore?
    private(set) var player:         ChannelPlayer?

    // MARK: – Boot
    func boot() async {
        guard let token = await auth.loadToken() else {
            route = .login; return
        }
        guard let serverURL = await resolveServer(token: token) else {
            setupServerSelection(token: token)
            route = .serverSelection; return
        }
        setupServices(serverURL: serverURL, token: token)
        guard let libraryStore else { route = .login; return }
        guard let channelStore else { route = .login; return }
        await libraryStore.load()
        guard libraryStore.hasSavedSelection, libraryStore.isValid else {
            route = .librarySelection; return
        }
        await channelStore.loadChannels(for: libraryStore.selection)
        route = .main
    }

    func didLogin(token: String) async {
        setupServerSelection(token: token)
        route = .serverSelection
    }

    func didSelectServer(_ server: AnaloqServer) async {
        guard let url = server.preferredConnection?.uri else { return }
        guard let token = await auth.loadToken() else {
            route = .login
            return
        }
        UserDefaults.standard.set(url, forKey: "serverURL")
        UserDefaults.standard.set(server.id, forKey: "serverID")
        setupServices(serverURL: url, token: token)
        guard let libraryStore else { route = .login; return }
        await libraryStore.load()
        if libraryStore.hasSavedSelection, libraryStore.isValid {
            await didSelectLibraries()
        } else {
            route = .librarySelection
        }
    }

    func didSelectLibraries() async {
        guard let libraryStore, let channelStore else { route = .login; return }
        await channelStore.loadChannels(for: libraryStore.selection)
        route = .main
    }

    func logout() {
        Task { await auth.logout() }
        UserDefaults.standard.removeObject(forKey: "serverURL")
        UserDefaults.standard.removeObject(forKey: "serverID")
        libraryStore?.reset()
        serverDiscovery = nil; libraryService = nil
        collectionService = nil; streamService = nil
        serverStore = nil; libraryStore = nil
        channelStore = nil; player = nil
        route = .login
    }

    // MARK: – Private
    private func resolveServer(token: String) async -> String? {
        guard let rawSavedURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }
        if let savedURL = await firstReachableServerURL(in: identityCandidates(for: rawSavedURL), token: token) {
            if savedURL != rawSavedURL {
                UserDefaults.standard.set(savedURL, forKey: "serverURL")
            }
            return savedURL
        }

        let discovery = ServerDiscoveryService(token: token)
        let preferredServerID = UserDefaults.standard.string(forKey: "serverID")
        let servers = try? await discovery.discoverServers(targetServerID: preferredServerID)
        guard let discoveredServer = servers?.first(where: { $0.preferredConnection != nil }),
              let discoveredURL = discoveredServer.preferredConnection?.uri else {
            return nil
        }

        UserDefaults.standard.set(discoveredURL, forKey: "serverURL")
        UserDefaults.standard.set(discoveredServer.id, forKey: "serverID")
        return discoveredURL
    }

    private func firstReachableServerURL(in candidates: [String], token: String) async -> String? {
        for candidate in candidates {
            guard let url = URL(string: candidate + "/identity") else { continue }
            var request = URLRequest(url: url, timeoutInterval: 2.2)
            request.setValue(token, forHTTPHeaderField: AnaloqProtocol.tokenHeader)
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return candidate
            }
        }
        return nil
    }

    private func identityCandidates(for baseURL: String) -> [String] {
        let normalized = normalizedServerURL(baseURL)
        if normalized == baseURL {
            return [baseURL]
        }
        return [baseURL, normalized]
    }

    private func normalizedServerURL(_ urlString: String) -> String {
        guard let components = URLComponents(string: urlString),
              let host = components.host,
              host.hasSuffix(AnaloqProtocol.directHostSuffix),
              let port = components.port else {
            return urlString
        }

        let labels = host.split(separator: ".")
        guard let firstLabel = labels.first else { return urlString }
        let ipCandidate = firstLabel.replacingOccurrences(of: "-", with: ".")
        let octets = ipCandidate.split(separator: ".")
        guard octets.count == 4,
              octets.allSatisfy({ part in
                  guard let value = Int(part) else { return false }
                  return (0...255).contains(value)
              }) else {
            return urlString
        }

        return "http://\(ipCandidate):\(port)"
    }

    private func setupServerSelection(token: String) {
        serverDiscovery = ServerDiscoveryService(token: token)
        serverStore = ServerSelectionViewModel(discovery: serverDiscovery!)
    }

    private func setupServices(serverURL: String, token: String) {
        let clientID = UserDefaults.standard.string(forKey: AnaloqProtocol.clientIDUserDefaultsKey)
            ?? UserDefaults.standard.string(forKey: AnaloqProtocol.legacyClientIDUserDefaultsKey)
            ?? ""
        collectionService = CollectionService(serverURL: serverURL, token: token)
        streamService     = StreamService(serverURL: serverURL, token: token, clientID: clientID)
        libraryService    = LibraryService(serverURL: serverURL, token: token)
        libraryStore      = LibrarySelectionStore(service: libraryService!)
        channelStore      = ChannelStore(service: collectionService!)
        player            = ChannelPlayer(service: collectionService!, streamService: streamService!)
    }
}
