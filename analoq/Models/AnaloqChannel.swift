import Foundation

struct AnaloqChannel: Identifiable {
    let id: String
    var number: Int
    let name: String
    let artworkPath: String?
    let itemCount: Int
    var items: [AnaloqItem] = []
}

struct AnaloqCollection: Codable {
    let id: String
    let title: String
    let thumb: String?
    let childCount: Int
    let subtype: String?

    var asChannel: AnaloqChannel {
        AnaloqChannel(id: id, number: 0, name: title, artworkPath: thumb, itemCount: childCount)
    }

    enum CodingKeys: String, CodingKey {
        case id = "ratingKey"
        case title, thumb, childCount, subtype
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let stringID = try? container.decode(String.self, forKey: .id) {
            id = stringID
        } else if let intID = try? container.decode(Int.self, forKey: .id) {
            id = String(intID)
        } else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: decoder.codingPath, debugDescription: "Missing collection id"))
        }

        title = (try? container.decode(String.self, forKey: .title)) ?? "Unbekannt"
        thumb = try? container.decode(String.self, forKey: .thumb)
        subtype = try? container.decode(String.self, forKey: .subtype)

        if let intCount = try? container.decode(Int.self, forKey: .childCount) {
            childCount = intCount
        } else if let stringCount = try? container.decode(String.self, forKey: .childCount),
                  let intCount = Int(stringCount) {
            childCount = intCount
        } else {
            childCount = 0
        }
    }
}
