import Foundation

struct AnaloqItem: Identifiable, Codable {
    let id: String
    let title: String
    let duration: TimeInterval      // milliseconds from server metadata
    let mediaKey: String?
    let thumb: String?
    let type: ItemType
    let grandparentTitle: String?
    let parentIndex: Int?
    let index: Int?

    var durationSeconds: TimeInterval { max(duration / 1000, 1) }

    var displayTitle: String {
        if type == .episode, let show = grandparentTitle {
            return "\(show) · S\(parentIndex ?? 0)E\(index ?? 0) · \(title)"
        }
        return title
    }

    enum ItemType: String, Codable {
        case movie, episode
    }

    enum CodingKeys: String, CodingKey {
        case id = "ratingKey"
        case title, duration, thumb, type
        case mediaKey = "key"
        case grandparentTitle, parentIndex, index
    }
}

struct AnaloqItemRaw: Codable {
    let id: String
    let title: String
    let type: String
    let duration: TimeInterval?
    let key: String?
    let thumb: String?
    let grandparentTitle: String?
    let parentIndex: Int?
    let index: Int?

    var durationSeconds: TimeInterval { (duration ?? 0) / 1000 }

    var asItem: AnaloqItem {
        AnaloqItem(
            id: id, title: title,
            duration: duration ?? 0,
            mediaKey: key,
            thumb: thumb,
            type: type == "movie" ? .movie : .episode,
            grandparentTitle: grandparentTitle,
            parentIndex: parentIndex,
            index: index
        )
    }

    enum CodingKeys: String, CodingKey {
        case id = "ratingKey"
        case title, type, duration, thumb
        case key
        case grandparentTitle, parentIndex, index
    }
}

// MARK: – Media Info Models
struct AnaloqMediaInfo: Codable {
    let id: String
    let media: [AnaloqMedia]
    enum CodingKeys: String, CodingKey {
        case id = "ratingKey"
        case media = "Media"
    }
}

struct AnaloqMedia: Codable {
    let id: Int
    let bitrate: Int?
    let videoCodec: String?
    let audioCodec: String?
    let container: String?
    let videoResolution: String?
    let parts: [AnaloqPart]
    enum CodingKeys: String, CodingKey {
        case id, bitrate, container
        case videoCodec, audioCodec, videoResolution
        case parts = "Part"
    }
}

struct AnaloqPart: Codable {
    let id: Int
    let key: String
    let duration: Int
    let file: String
    let size: Int64
    let streams: [AnaloqStream]
    enum CodingKeys: String, CodingKey {
        case id, key, duration, file, size
        case streams = "Stream"
    }
}

struct AnaloqStream: Codable {
    let streamType: Int
    let codec: String?
    let language: String?
    let selected: Bool?
    var isVideo: Bool    { streamType == 1 }
    var isAudio: Bool    { streamType == 2 }
    var isSubtitle: Bool { streamType == 3 }
}
