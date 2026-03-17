import Foundation

struct EPGEntry: Identifiable {
    let id: String
    let channel: AnaloqChannel
    let item: AnaloqItem
    let startDate: Date
    let endDate: Date
    let startTimeString: String
    let endTimeString: String

    init(channel: AnaloqChannel, item: AnaloqItem, startDate: Date, endDate: Date) {
        let ts = Int(startDate.timeIntervalSince1970)
        self.id = "\(channel.id)|\(item.id)|\(ts)"
        self.channel = channel
        self.item = item
        self.startDate = startDate
        self.endDate = endDate
        self.startTimeString = startDate.formatted(.dateTime.hour().minute())
        self.endTimeString = endDate.formatted(.dateTime.hour().minute())
    }

    var isLive: Bool  { (startDate...endDate).contains(.now) }
    var isPast: Bool  { endDate < .now }
    var duration: TimeInterval { endDate.timeIntervalSince(startDate) }
    var remaining: TimeInterval { max(0, endDate.timeIntervalSinceNow) }

    var progress: Double {
        guard isLive else { return isPast ? 1 : 0 }
        return Date.now.timeIntervalSince(startDate) / duration
    }
}

struct EPGGenerator {
    private let scheduler = ChannelScheduler()
    private let maxEntriesPerChannel = 180

    func generate(for channels: [AnaloqChannel], from: Date = .now, hours: Int = 6) -> [String: [EPGEntry]] {
        var result: [String: [EPGEntry]] = [:]
        for channel in channels where !channel.items.isEmpty {
            result[channel.id] = entries(for: channel, from: from, hours: hours)
        }
        return result
    }

    private func entries(for channel: AnaloqChannel, from: Date, hours: Int) -> [EPGEntry] {
        var entries: [EPGEntry] = []
        guard let first = scheduler.currentItem(for: channel, at: from) else { return [] }
        var cursor = from.addingTimeInterval(-first.startOffset)
        let end = from.addingTimeInterval(TimeInterval(hours * 3600))

        while cursor < end && entries.count < maxEntriesPerChannel {
            guard let scheduled = scheduler.currentItem(for: channel, at: cursor + 0.1) else { break }
            entries.append(EPGEntry(
                channel: channel,
                item: scheduled.item,
                startDate: cursor,
                endDate: scheduled.endsAt
            ))
            cursor = scheduled.endsAt
        }
        return entries
    }
}
