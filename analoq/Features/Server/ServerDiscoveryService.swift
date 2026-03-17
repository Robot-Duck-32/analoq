import Foundation

actor ServerDiscoveryService {

    private let token: String
    private let clientID: String
    private let appName = "analoq"
    private let appVersion = "1.0"
    private let localTimeout: TimeInterval = 1.6
    private let remoteTimeout: TimeInterval = 2.8
    #if os(tvOS)
    private let platform = "tvOS"
    #elseif os(iOS)
    private let platform = "iOS"
    #else
    private let platform = "Apple"
    #endif

    init(token: String) {
        self.token = token
        self.clientID = UserDefaults.standard.string(forKey: AnaloqProtocol.clientIDUserDefaultsKey)
            ?? UserDefaults.standard.string(forKey: AnaloqProtocol.legacyClientIDUserDefaultsKey)
            ?? {
            let id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: AnaloqProtocol.clientIDUserDefaultsKey)
            return id
        }()
    }

    private var headers: [String: String] {
        [
            AnaloqProtocol.clientIdentifierHeader: clientID,
            AnaloqProtocol.productHeader: appName,
            AnaloqProtocol.versionHeader: appVersion,
            AnaloqProtocol.platformHeader: platform,
            AnaloqProtocol.deviceHeader: platform,
            AnaloqProtocol.deviceNameHeader: appName,
            AnaloqProtocol.modelHeader: platform,
            "Accept": "application/json",
            AnaloqProtocol.tokenHeader: token
        ]
    }

    func discoverServers(targetServerID: String? = nil) async throws -> [AnaloqServer] {
        let raw = try await fetchResources()
        let candidates: [AnaloqServer]
        if let targetServerID {
            let filtered = raw.filter { $0.id == targetServerID }
            candidates = filtered.isEmpty ? raw : filtered
        } else {
            candidates = raw
        }

        var results: [AnaloqServer] = []
        for server in candidates {
            var s = server
            s.preferredConnection = await findBestConnection(for: server)
            results.append(s)
        }

        return results.sorted {
            ($0.preferredConnection?.local ?? false) && !($1.preferredConnection?.local ?? false)
        }
    }

    private func fetchResources() async throws -> [AnaloqServer] {
        var components = URLComponents(string: AnaloqProtocol.apiBaseURL + "/api/v2/resources")!
        components.queryItems = [
            URLQueryItem(name: "includeHttps",  value: "1"),
            URLQueryItem(name: "includeRelay",  value: "1"),
            URLQueryItem(name: "includeIPv6",   value: "0"),
        ]
        var request = URLRequest(url: components.url!)
        request.allHTTPHeaderFields = headers
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if let apiError = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data).errors.first {
                throw DiscoveryError.api(status: apiError.status ?? http.statusCode, message: apiError.message)
            }
            throw DiscoveryError.api(status: http.statusCode, message: nil)
        }

        if let apiError = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data).errors.first {
            throw DiscoveryError.api(status: apiError.status ?? 0, message: apiError.message)
        }

        let all = try JSONDecoder().decode([AnaloqResource].self, from: data)
        return all.filter { $0.provides.contains("server") && $0.owned }.map(\.asServer)
    }

    private func findBestConnection(for server: AnaloqServer) async -> AnaloqConnection? {
        for connection in prioritizedConnections(from: server.connections) {
            if let (conn, _) = await ping(connection: connection) {
                return conn
            }
        }
        return nil
    }

    private func ping(connection: AnaloqConnection) async -> (AnaloqConnection, TimeInterval)? {
        let start = Date()
        for candidate in connectionCandidates(for: connection) {
            guard let url = identityURL(for: candidate.uri) else { continue }
            if await isReachable(url: url, timeout: timeout(for: candidate)) {
                return (candidate, Date().timeIntervalSince(start))
            }
        }
        return nil
    }

    private func isReachable(url: URL, timeout: TimeInterval) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.allHTTPHeaderFields = headers
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            // Any HTTP response means host is reachable for our selection purpose.
            return (100...499).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func identityURL(for baseURI: String) -> URL? {
        guard let base = URL(string: baseURI) else { return nil }
        return base.appendingPathComponent("identity")
    }

    private func connectionCandidates(for connection: AnaloqConnection) -> [AnaloqConnection] {
        var candidates: [AnaloqConnection] = []
        if let fallback = httpFallbackConnection(for: connection) {
            candidates.append(fallback)
        }
        candidates.append(connection)

        var seen: Set<String> = []
        return candidates.filter { candidate in
            let key = "\(candidate.protocol_.lowercased())|\(candidate.address)|\(candidate.port)|\(candidate.uri)"
            return seen.insert(key).inserted
        }
    }

    private func httpFallbackConnection(for connection: AnaloqConnection) -> AnaloqConnection? {
        guard connection.local, !connection.relay, connection.protocol_.lowercased() == "https" else {
            return nil
        }
        return normalizedConnection(connection)
    }

    private func normalizedConnection(_ connection: AnaloqConnection) -> AnaloqConnection {
        guard connection.local, !connection.relay else { return connection }
        let rawHost = connection.address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let host = rawHost.contains(":") ? "[\(rawHost)]" : rawHost
        let localURI = "http://\(host):\(connection.port)"
        return AnaloqConnection(
            protocol_: "http",
            address: connection.address,
            port: connection.port,
            uri: localURI,
            local: connection.local,
            relay: connection.relay
        )
    }

    private func prioritizedConnections(from connections: [AnaloqConnection]) -> [AnaloqConnection] {
        let sorted = connections.sorted { priority($0) > priority($1) }
        var seen: Set<String> = []
        var result: [AnaloqConnection] = []
        for connection in sorted {
            let key = "\(connection.protocol_.lowercased())|\(connection.address)|\(connection.port)"
            if seen.insert(key).inserted {
                result.append(connection)
            }
            if result.count >= 6 { break }
        }
        return result
    }

    private func timeout(for connection: AnaloqConnection) -> TimeInterval {
        (connection.local && !connection.relay) ? localTimeout : remoteTimeout
    }

    private func priority(_ c: AnaloqConnection) -> Int {
        switch (c.local, c.relay) {
        case (true,  false):
            if c.protocol_.lowercased() == "http" { return 34 }
            return 30
        case (true,  true):
            return 20
        case (false, false):
            return c.protocol_.lowercased() == "https" ? 14 : 12
        case (false, true):
            return 8
        }
    }
}

private struct APIErrorEnvelope: Decodable {
    let errors: [APIErrorDetail]
}

private struct APIErrorDetail: Decodable {
    let code: Int?
    let message: String?
    let status: Int?
}

private enum DiscoveryError: LocalizedError {
    case api(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .api(let status, let message):
            if status == 401 {
                return L10n.tr("discovery.invalid_or_expired_token")
            }
            if status == 400, let message, message.localizedCaseInsensitiveContains("Client-Identifier") {
                return L10n.tr("discovery.missing_client_identifier")
            }
            if let message, !message.isEmpty {
                return L10n.tr("error.server_api.with_message", status, message)
            }
            return L10n.tr("error.server_api.without_message", status)
        }
    }
}

private struct AnaloqResource: Codable {
    let clientIdentifier: String
    let name: String
    let productVersion: String
    let provides: String
    let owned: Bool
    let connections: [AnaloqConnection]
    var asServer: AnaloqServer {
        AnaloqServer(id: clientIdentifier, name: name,
                   productVersion: productVersion, connections: connections)
    }
}
