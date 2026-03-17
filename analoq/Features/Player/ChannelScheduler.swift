import Foundation

struct ScheduledItem {
    let item: AnaloqItem
    let startOffset: TimeInterval
    let endsAt: Date
}

struct ChannelScheduler {

    private struct PlaylistCacheEntry {
        let itemCount: Int
        let firstItemID: String
        let lastItemID: String
        let items: [AnaloqItem]
        let cumulativeEnds: [TimeInterval]
        let totalDuration: TimeInterval
    }

    private static var playlistCache: [String: PlaylistCacheEntry] = [:]
    private static let playlistCacheLock = NSLock()

    func currentItem(for channel: AnaloqChannel, at date: Date = .now) -> ScheduledItem? {
        guard let playlist = playlist(for: channel), playlist.totalDuration > 0 else { return nil }

        let epoch = channelEpoch(for: channel)
        var elapsed = date.timeIntervalSince(epoch).truncatingRemainder(dividingBy: playlist.totalDuration)
        if elapsed < 0 { elapsed += playlist.totalDuration }

        guard let index = indexOfCurrentItem(for: elapsed, in: playlist.cumulativeEnds) else { return nil }
        let end = playlist.cumulativeEnds[index]
        let start = index == 0 ? 0 : playlist.cumulativeEnds[index - 1]
        let item = playlist.items[index]
        return ScheduledItem(
            item: item,
            startOffset: elapsed - start,
            endsAt: date.addingTimeInterval(end - elapsed)
        )
    }

    func nextItem(for channel: AnaloqChannel, at date: Date = .now) -> ScheduledItem? {
        guard let current = currentItem(for: channel, at: date) else { return nil }
        return currentItem(for: channel, at: current.endsAt + 0.1)
    }

    func schedule(for channel: AnaloqChannel, hours: Int = 6, from date: Date = .now) -> [ScheduledItem] {
        var entries: [ScheduledItem] = []
        guard let first = currentItem(for: channel, at: date) else { return [] }
        entries.append(ScheduledItem(item: first.item, startOffset: 0, endsAt: first.endsAt))
        var cursor = first.endsAt
        let end = date.addingTimeInterval(TimeInterval(hours * 3600))
        while cursor < end {
            guard let next = currentItem(for: channel, at: cursor + 0.1) else { break }
            entries.append(next); cursor = next.endsAt
        }
        return entries
    }

    private func channelEpoch(for channel: AnaloqChannel) -> Date {
        var hasher = Hasher(); hasher.combine(channel.id)
        let hash = abs(hasher.finalize())
        let offset = TimeInterval(hash % (30 * 24 * 3600))
        let reference = Date(timeIntervalSince1970: 1_704_067_200)
        return reference.addingTimeInterval(-offset)
    }

    private func shuffled(_ items: [AnaloqItem], seed: String) -> [AnaloqItem] {
        var rng = SeededRNG(seed: seed)
        return items.shuffled(using: &rng)
    }

    private func episodePairsPlaylist(_ items: [AnaloqItem], seed: String) -> [AnaloqItem] {
        guard !items.isEmpty else { return [] }

        let grouped = Dictionary(grouping: items, by: seriesKey(for:))
            .mapValues { episodes in
                episodes.sorted(by: episodeOrder(_:_:))
            }

        var rng = SeededRNG(seed: "\(seed)-series-order")
        let tieBreakOrder = grouped.keys.sorted().shuffled(using: &rng)
        let tieBreakRank = Dictionary(uniqueKeysWithValues: tieBreakOrder.enumerated().map { ($0.element, $0.offset) })
        var best = reorderForLoopBoundary(
            buildEpisodeOrder(
                grouped: grouped,
                tieBreakRank: tieBreakRank,
                forceFirstSeries: nil
            )
        )
        var bestRun = maxConsecutiveRun(in: best, circular: true)
        if bestRun <= 2 {
            return best
        }

        for firstSeries in tieBreakOrder {
            let attempt = reorderForLoopBoundary(
                buildEpisodeOrder(
                    grouped: grouped,
                    tieBreakRank: tieBreakRank,
                    forceFirstSeries: firstSeries
                )
            )
            let run = maxConsecutiveRun(in: attempt, circular: true)
            if run < bestRun {
                best = attempt
                bestRun = run
            }
            if run <= 2 {
                return attempt
            }
        }

        return best
    }

    private func buildEpisodeOrder(
        grouped: [String: [AnaloqItem]],
        tieBreakRank: [String: Int],
        forceFirstSeries: String?
    ) -> [AnaloqItem] {
        let totalCount = grouped.values.reduce(0) { $0 + $1.count }
        var positions = Dictionary(uniqueKeysWithValues: grouped.keys.map { ($0, 0) })
        var ordered: [AnaloqItem] = []
        ordered.reserveCapacity(totalCount)
        var lastSeries: String?
        var consecutiveCount = 0

        if let forceFirstSeries,
           let firstEpisodes = grouped[forceFirstSeries],
           let firstEpisode = firstEpisodes.first {
            ordered.append(firstEpisode)
            positions[forceFirstSeries] = 1
            lastSeries = forceFirstSeries
            consecutiveCount = 1
        }

        while ordered.count < totalCount {
            let availableSeries = grouped.keys.filter { series in
                let start = positions[series] ?? 0
                guard let episodes = grouped[series] else { return false }
                return start < episodes.count
            }

            guard !availableSeries.isEmpty else { break }

            let hasAlternative = {
                guard let lastSeries else { return false }
                return availableSeries.contains { $0 != lastSeries }
            }()
            let candidateSeries: [String]
            if hasAlternative, let lastSeries, consecutiveCount >= 2 {
                candidateSeries = availableSeries.filter { $0 != lastSeries }
            } else {
                candidateSeries = availableSeries
            }

            guard let selectedSeries = candidateSeries.max(by: { lhs, rhs in
                let lhsRemaining = remainingEpisodes(for: lhs, grouped: grouped, positions: positions)
                let rhsRemaining = remainingEpisodes(for: rhs, grouped: grouped, positions: positions)
                if lhsRemaining != rhsRemaining { return lhsRemaining < rhsRemaining }
                let lhsRank = tieBreakRank[lhs] ?? .max
                let rhsRank = tieBreakRank[rhs] ?? .max
                return lhsRank > rhsRank
            }) else {
                break
            }

            guard let episodes = grouped[selectedSeries] else { continue }
            let start = positions[selectedSeries] ?? 0
            guard start < episodes.count else { continue }

            ordered.append(episodes[start])
            positions[selectedSeries] = start + 1

            if selectedSeries == lastSeries {
                consecutiveCount += 1
            } else {
                lastSeries = selectedSeries
                consecutiveCount = 1
            }
        }

        return ordered
    }

    private func remainingEpisodes(
        for series: String,
        grouped: [String: [AnaloqItem]],
        positions: [String: Int]
    ) -> Int {
        let total = grouped[series]?.count ?? 0
        let consumed = positions[series] ?? 0
        return max(total - consumed, 0)
    }

    private func reorderForLoopBoundary(_ items: [AnaloqItem]) -> [AnaloqItem] {
        guard items.count > 2 else { return items }
        guard maxConsecutiveRun(in: items, circular: true) > 2 else { return items }

        for offset in 1..<items.count {
            var rotated: [AnaloqItem] = []
            rotated.reserveCapacity(items.count)
            rotated.append(contentsOf: items[offset...])
            rotated.append(contentsOf: items[..<offset])
            if maxConsecutiveRun(in: rotated, circular: true) <= 2 {
                return rotated
            }
        }
        return items
    }

    private func maxConsecutiveRun(in items: [AnaloqItem], circular: Bool) -> Int {
        guard !items.isEmpty else { return 0 }
        let keys = items.map(seriesKey(for:))
        var maxRun = 1
        var currentRun = 1

        if keys.count > 1 {
            for index in 1..<keys.count {
                if keys[index] == keys[index - 1] {
                    currentRun += 1
                    maxRun = max(maxRun, currentRun)
                } else {
                    currentRun = 1
                }
            }
        }

        guard circular, keys.count > 1, keys.first == keys.last else {
            return maxRun
        }

        var prefixRun = 1
        while prefixRun < keys.count, keys[prefixRun] == keys[0] {
            prefixRun += 1
        }

        var suffixRun = 1
        while suffixRun < keys.count, keys[keys.count - suffixRun - 1] == keys[keys.count - 1] {
            suffixRun += 1
        }

        return min(max(maxRun, prefixRun + suffixRun), keys.count)
    }

    private func seriesKey(for item: AnaloqItem) -> String {
        if let title = item.grandparentTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return "__single__\(item.id)"
    }

    private func episodeOrder(_ lhs: AnaloqItem, _ rhs: AnaloqItem) -> Bool {
        let lhsSeason = lhs.parentIndex ?? 0
        let rhsSeason = rhs.parentIndex ?? 0
        if lhsSeason != rhsSeason { return lhsSeason < rhsSeason }

        let lhsEpisode = lhs.index ?? 0
        let rhsEpisode = rhs.index ?? 0
        if lhsEpisode != rhsEpisode { return lhsEpisode < rhsEpisode }

        if lhs.title != rhs.title {
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    private func playlist(for channel: AnaloqChannel) -> PlaylistCacheEntry? {
        guard !channel.items.isEmpty else { return nil }

        let firstItemID = channel.items.first?.id ?? ""
        let lastItemID = channel.items.last?.id ?? ""

        Self.playlistCacheLock.lock()
        if let cached = Self.playlistCache[channel.id],
           cached.itemCount == channel.items.count,
           cached.firstItemID == firstItemID,
           cached.lastItemID == lastItemID {
            Self.playlistCacheLock.unlock()
            return cached
        }
        Self.playlistCacheLock.unlock()

        let playlistItems: [AnaloqItem]
        if channel.items.allSatisfy({ $0.type == .episode }) {
            playlistItems = episodePairsPlaylist(channel.items, seed: channel.id)
        } else {
            playlistItems = shuffled(channel.items, seed: channel.id)
        }

        var cumulativeEnds: [TimeInterval] = []
        cumulativeEnds.reserveCapacity(playlistItems.count)
        var runningTotal: TimeInterval = 0
        for item in playlistItems {
            runningTotal += item.durationSeconds
            cumulativeEnds.append(runningTotal)
        }
        let entry = PlaylistCacheEntry(
            itemCount: channel.items.count,
            firstItemID: firstItemID,
            lastItemID: lastItemID,
            items: playlistItems,
            cumulativeEnds: cumulativeEnds,
            totalDuration: runningTotal
        )

        Self.playlistCacheLock.lock()
        Self.playlistCache[channel.id] = entry
        Self.playlistCacheLock.unlock()
        return entry
    }

    private func indexOfCurrentItem(for elapsed: TimeInterval, in cumulativeEnds: [TimeInterval]) -> Int? {
        guard !cumulativeEnds.isEmpty else { return nil }
        var low = 0
        var high = cumulativeEnds.count - 1

        while low < high {
            let mid = (low + high) / 2
            if elapsed < cumulativeEnds[mid] {
                high = mid
            } else {
                low = mid + 1
            }
        }

        return elapsed < cumulativeEnds[low] ? low : nil
    }
}
