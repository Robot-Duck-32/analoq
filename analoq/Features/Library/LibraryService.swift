import Foundation

actor LibraryService {

    private let serverURL: String
    private let token: String

    init(serverURL: String, token: String) {
        self.serverURL = serverURL
        self.token = token
    }

    func fetchLibraries() async throws -> [AnaloqLibrary] {
        var request = URLRequest(url: URL(string: serverURL + "/library/sections")!)
        request.setValue(token,              forHTTPHeaderField: AnaloqProtocol.tokenHeader)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        let container = try JSONDecoder().decode(MediaContainer<AnaloqLibrary>.self, from: data)
        return container.metadata.filter { $0.type.isSupported }.sorted { $0.type.rawValue < $1.type.rawValue }
    }

    func fetchChannels(for selection: LibrarySelection) async throws -> [AnaloqChannel] {
        guard !selection.selectedIDs.isEmpty else { return [] }
        let channels = try await withThrowingTaskGroup(of: [AnaloqChannel].self) { group in
            for libraryID in selection.selectedIDs {
                group.addTask { try await self.fetchCollections(libraryID: libraryID) }
            }
            var all: [AnaloqChannel] = []
            for try await result in group { all.append(contentsOf: result) }
            return all
        }
        return channels.sorted { $0.name < $1.name }.enumerated().map { idx, ch in
            var c = ch; c.number = idx + 1; return c
        }
    }

    private func fetchCollections(libraryID: String) async throws -> [AnaloqChannel] {
        let url = serverURL + "/library/sections/\(libraryID)/collections"
        var request = URLRequest(url: URL(string: url)!)
        request.setValue(token,              forHTTPHeaderField: AnaloqProtocol.tokenHeader)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        let container = try JSONDecoder().decode(MediaContainer<AnaloqCollection>.self, from: data)
        return container.metadata.filter { $0.childCount > 0 }.map { $0.asChannel }
    }
}
