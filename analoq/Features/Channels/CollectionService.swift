import Foundation

actor CollectionService {

    nonisolated let serverURL: String
    nonisolated let token: String
    private var itemCache: [String: [AnaloqItem]] = [:]

    init(serverURL: String, token: String) {
        self.serverURL = serverURL
        self.token = token
    }

    func fetchItems(for channel: AnaloqChannel) async throws -> [AnaloqItem] {
        if let cached = itemCache[channel.id] { return cached }
        let url = "\(serverURL)/library/collections/\(channel.id)/children"
        let response: MediaContainer<AnaloqItemRaw> = try await get(url)
        let items = try await resolveEpisodes(from: response.metadata)
        itemCache[channel.id] = items
        return items
    }

    private func resolveEpisodes(from raw: [AnaloqItemRaw]) async throws -> [AnaloqItem] {
        // Use indexed results to preserve insertion order despite concurrent execution.
        var indexed: [(index: Int, items: [AnaloqItem])] = []
        try await withThrowingTaskGroup(of: (Int, [AnaloqItem]).self) { group in
            for (index, item) in raw.enumerated() {
                group.addTask {
                    switch item.type {
                    case "movie", "episode":
                        return (index, item.durationSeconds > 0 ? [item.asItem] : [])
                    case "show":
                        let url = "\(self.serverURL)/library/metadata/\(item.id)/allLeaves"
                        let resp: MediaContainer<AnaloqItemRaw> = try await self.get(url)
                        return (index, resp.metadata.filter { $0.durationSeconds > 0 }.map(\.asItem))
                    case "season":
                        let url = "\(self.serverURL)/library/metadata/\(item.id)/children"
                        let resp: MediaContainer<AnaloqItemRaw> = try await self.get(url)
                        return (index, resp.metadata.filter { $0.durationSeconds > 0 }.map(\.asItem))
                    default:
                        return (index, item.durationSeconds > 0 ? [item.asItem] : [])
                    }
                }
            }
            for try await pair in group { indexed.append(pair) }
        }
        return indexed.sorted { $0.index < $1.index }.flatMap(\.items)
    }

    func streamURL(for item: AnaloqItem) -> URL {
        var components = URLComponents(string: "\(serverURL)/library/parts/\(item.id)/file")!
        components.queryItems = [
            URLQueryItem(name: AnaloqProtocol.tokenHeader, value: token),
            URLQueryItem(name: "download",      value: "0"),
        ]
        return components.url!
    }

    nonisolated func artworkURL(path: String?, width: Int = 400) -> URL? {
        guard let path else { return nil }
        var components = URLComponents(string: "\(serverURL)/photo/:/transcode")!
        components.queryItems = [
            URLQueryItem(name: "url",          value: path),
            URLQueryItem(name: "width",         value: "\(width)"),
            URLQueryItem(name: "height",        value: "\(width)"),
            URLQueryItem(name: AnaloqProtocol.tokenHeader, value: token),
        ]
        return components.url
    }

    func get<T: Decodable>(_ urlString: String) async throws -> T {
        var request = URLRequest(url: URL(string: urlString)!)
        request.setValue(token,              forHTTPHeaderField: AnaloqProtocol.tokenHeader)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CollectionError.httpError(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    enum CollectionError: LocalizedError {
        case httpError(Int)
        var errorDescription: String? {
            switch self {
            case .httpError(let status):
                return L10n.tr("collection.http_error", status)
            }
        }
    }
}
