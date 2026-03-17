import Foundation

struct AnaloqLibrary: Identifiable, Decodable {
    let id: String
    let title: String
    let type: LibraryType
    let thumb: String?
    let itemCount: Int

    enum LibraryType: String, Codable {
        case movie  = "movie"
        case show   = "show"
        case music  = "artist"
        case photo  = "photo"
        case other

        var isSupported: Bool { self == .movie || self == .show }

        var icon: String {
            switch self {
            case .movie: return "film"
            case .show:  return "tv"
            case .music: return "music.note"
            case .photo: return "photo"
            case .other: return "questionmark"
            }
        }

        var label: String {
            switch self {
            case .movie: return L10n.tr("library.type.movie")
            case .show:  return L10n.tr("library.type.show")
            case .music: return L10n.tr("library.type.music")
            case .photo: return L10n.tr("library.type.photo")
            case .other: return L10n.tr("library.type.other")
            }
        }

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = LibraryType(rawValue: raw) ?? .other
        }
    }

    enum CodingKeys: String, CodingKey {
        case id = "key"
        case title, type, thumb
        case itemCount = "count"
        case totalSize
        case leafCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let stringID = try? container.decode(String.self, forKey: .id) {
            id = stringID
        } else if let intID = try? container.decode(Int.self, forKey: .id) {
            id = String(intID)
        } else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: decoder.codingPath, debugDescription: "Missing library id"))
        }

        title = (try? container.decode(String.self, forKey: .title)) ?? L10n.tr("library.unknown")
        type = (try? container.decode(LibraryType.self, forKey: .type)) ?? .other
        thumb = try? container.decode(String.self, forKey: .thumb)

        func decodeInt(for key: CodingKeys) -> Int? {
            if let intValue = try? container.decode(Int.self, forKey: key) { return intValue }
            if let stringValue = try? container.decode(String.self, forKey: key),
               let intValue = Int(stringValue) { return intValue }
            return nil
        }

        itemCount =
            decodeInt(for: .itemCount) ??
            decodeInt(for: .totalSize) ??
            decodeInt(for: .leafCount) ??
            0
    }
}

struct LibrarySelection: Codable {
    var selectedIDs: Set<String>
    static let empty = LibrarySelection(selectedIDs: [])
}
