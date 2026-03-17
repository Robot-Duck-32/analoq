import Foundation

struct AnaloqServer: Identifiable, Codable {
    let id: String
    let name: String
    let productVersion: String
    let connections: [AnaloqConnection]
    var preferredConnection: AnaloqConnection?
    var isReachable: Bool { preferredConnection != nil }
    enum CodingKeys: String, CodingKey {
        case id = "clientIdentifier"
        case name, productVersion, connections
    }
}

struct AnaloqConnection: Codable {
    let protocol_: String
    let address: String
    let port: Int
    let uri: String
    let local: Bool
    let relay: Bool
    var isPreferred: Bool { local && !relay }
    enum CodingKeys: String, CodingKey {
        case protocol_ = "protocol"
        case address, port, uri, local, relay
    }
}
