import Foundation

@MainActor
class ChannelStore: ObservableObject {

    enum LoadState: Equatable { case idle, loading, ready, error(String) }

    @Published var channels:       [AnaloqChannel] = []
    @Published var loadingState:   LoadState = .idle
    @Published var itemLoadStates: [String: LoadState] = [:]
    @Published private(set) var favoriteChannelIDs: Set<String> = []
    @Published private(set) var hiddenChannelIDs: Set<String> = []

    private let service: CollectionService
    private var allChannels: [AnaloqChannel] = []
    private let favoritesKey = "favoriteChannelIDs"
    private let hiddenKey = "hiddenChannelIDs"
    private let autoHiddenSeededKey = "autoHiddenSeededChannelIDs"
    private let minimumVisibleItemCount = 4

    init(service: CollectionService) {
        self.service = service
        restorePreferences()
    }

    func loadChannels(for selection: LibrarySelection) async {
        loadingState = .loading
        do {
            // Fetch channels via library IDs
            var indexed: [(index: Int, channels: [AnaloqChannel])] = []
            try await withThrowingTaskGroup(of: (Int, [AnaloqChannel]).self) { group in
                for (index, id) in selection.selectedIDs.enumerated() {
                    group.addTask {
                        let url = "\(self.service.serverURL)/library/sections/\(id)/collections"
                        let resp: MediaContainer<AnaloqCollection> = try await self.service.get(url)
                        let channels = resp.metadata.filter { $0.childCount > 0 }.map { $0.asChannel }
                        return (index, channels)
                    }
                }
                for try await pair in group { indexed.append(pair) }
            }
            let all = indexed.sorted { $0.index < $1.index }.flatMap(\.channels)
            allChannels = all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            sanitizePreferencesForLoadedChannels()
            applyAutoHiddenDefaultsForSmallCollections()
            applyVisibilityAndSorting()
            loadingState = .ready
            for channel in allChannels {
                Task(priority: .background) { await self.loadItems(for: channel) }
            }
        } catch {
            loadingState = .error(error.localizedDescription)
        }
    }

    func loadItems(for channel: AnaloqChannel) async {
        guard itemLoadStates[channel.id] != .ready else { return }
        itemLoadStates[channel.id] = .loading
        do {
            let items = try await service.fetchItems(for: channel)
            if let idx = allChannels.firstIndex(where: { $0.id == channel.id }) {
                allChannels[idx].items = items
            }
            if let idx = channels.firstIndex(where: { $0.id == channel.id }) {
                channels[idx].items = items
            }
            itemLoadStates[channel.id] = .ready
        } catch {
            itemLoadStates[channel.id] = .error(error.localizedDescription)
        }
    }

    func artworkURL(for channel: AnaloqChannel, width: Int = 400) -> URL? {
        service.artworkURL(path: channel.artworkPath, width: width)
    }

    func artworkURL(path: String?, width: Int = 400) -> URL? {
        service.artworkURL(path: path, width: width)
    }

    var channelsIncludingHidden: [AnaloqChannel] {
        rankedChannels(includeHidden: true).enumerated().map { idx, channel in
            var updated = channel
            updated.number = idx + 1
            return updated
        }
    }

    func isFavorite(_ channelID: String) -> Bool {
        favoriteChannelIDs.contains(channelID)
    }

    func isHidden(_ channelID: String) -> Bool {
        hiddenChannelIDs.contains(channelID)
    }

    @discardableResult
    func toggleFavorite(channelID: String) -> Bool {
        if favoriteChannelIDs.contains(channelID) {
            favoriteChannelIDs.remove(channelID)
        } else {
            favoriteChannelIDs.insert(channelID)
            hiddenChannelIDs.remove(channelID)
        }
        persistPreferences()
        applyVisibilityAndSorting()
        return favoriteChannelIDs.contains(channelID)
    }

    @discardableResult
    func toggleHidden(channelID: String) -> Bool {
        if hiddenChannelIDs.contains(channelID) {
            hiddenChannelIDs.remove(channelID)
        } else {
            hiddenChannelIDs.insert(channelID)
            favoriteChannelIDs.remove(channelID)
        }
        persistPreferences()
        applyVisibilityAndSorting()
        return hiddenChannelIDs.contains(channelID)
    }

    private func applyVisibilityAndSorting() {
        let visible = rankedChannels(includeHidden: false)
        channels = visible.enumerated().map { idx, channel in
            var updated = channel
            updated.number = idx + 1
            return updated
        }
    }

    private func rankedChannels(includeHidden: Bool) -> [AnaloqChannel] {
        allChannels
            .filter { includeHidden || !hiddenChannelIDs.contains($0.id) }
            .sorted { lhs, rhs in
                let lhsFav = favoriteChannelIDs.contains(lhs.id)
                let rhsFav = favoriteChannelIDs.contains(rhs.id)
                if lhsFav != rhsFav { return lhsFav && !rhsFav }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func restorePreferences() {
        let defaults = UserDefaults.standard
        let favorites = defaults.stringArray(forKey: favoritesKey) ?? []
        let hidden = defaults.stringArray(forKey: hiddenKey) ?? []
        favoriteChannelIDs = Set(favorites)
        hiddenChannelIDs = Set(hidden)
    }

    private func persistPreferences() {
        let defaults = UserDefaults.standard
        defaults.set(Array(favoriteChannelIDs), forKey: favoritesKey)
        defaults.set(Array(hiddenChannelIDs), forKey: hiddenKey)
    }

    private func sanitizePreferencesForLoadedChannels() {
        let validIDs = Set(allChannels.map(\.id))
        favoriteChannelIDs = favoriteChannelIDs.intersection(validIDs)
        hiddenChannelIDs = hiddenChannelIDs.intersection(validIDs)
        let defaults = UserDefaults.standard
        let seeded = Set(defaults.stringArray(forKey: autoHiddenSeededKey) ?? [])
        defaults.set(Array(seeded.intersection(validIDs)), forKey: autoHiddenSeededKey)
        persistPreferences()
    }

    private func applyAutoHiddenDefaultsForSmallCollections() {
        let defaults = UserDefaults.standard
        var seeded = Set(defaults.stringArray(forKey: autoHiddenSeededKey) ?? [])

        let smallCollectionIDs = Set(
            allChannels
                .filter { $0.itemCount < minimumVisibleItemCount }
                .map(\.id)
        )
        let newAutoHiddenIDs = smallCollectionIDs.subtracting(seeded)
        guard !newAutoHiddenIDs.isEmpty else { return }

        hiddenChannelIDs.formUnion(newAutoHiddenIDs)
        favoriteChannelIDs.subtract(newAutoHiddenIDs)
        seeded.formUnion(newAutoHiddenIDs)

        defaults.set(Array(seeded), forKey: autoHiddenSeededKey)
        persistPreferences()
    }
}
