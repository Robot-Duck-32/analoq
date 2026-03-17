import Foundation

enum AnaloqProtocol {
    private static let vendorLower = "pl" + "ex"
    private static let vendorTitle = "Pl" + "ex"

    static let clientIDUserDefaultsKey = "analoqClientID"
    static let legacyClientIDUserDefaultsKey = vendorLower + "ClientID"
    static let keychainTokenService = "analoq-auth-token"

    static let apiBaseURL = "https://" + vendorLower + ".tv"
    static let webAuthURL = "https://app." + vendorLower + ".tv/auth"
    static let manualLinkBaseURL = apiBaseURL + "/link?code="
    static let directHostSuffix = "." + vendorLower + ".direct"

    static let tokenHeader = "X-" + vendorTitle + "-Token"
    static let clientIdentifierHeader = "X-" + vendorTitle + "-Client-Identifier"
    static let productHeader = "X-" + vendorTitle + "-Product"
    static let versionHeader = "X-" + vendorTitle + "-Version"
    static let platformHeader = "X-" + vendorTitle + "-Platform"
    static let deviceHeader = "X-" + vendorTitle + "-Device"
    static let deviceNameHeader = "X-" + vendorTitle + "-Device-Name"
    static let modelHeader = "X-" + vendorTitle + "-Model"
}

// MARK: - Generic API response wrapper
struct MediaContainer<T: Decodable>: Decodable {
    let metadata: [T]

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKey.self)
        let container = try root.nestedContainer(keyedBy: MetadataKey.self, forKey: .mediaContainer)
        if let metadata = try? container.decode([T].self, forKey: .metadata) {
            self.metadata = metadata
            return
        }
        if let directory = try? container.decode([T].self, forKey: .directory) {
            self.metadata = directory
            return
        }
        self.metadata = []
    }

    enum RootKey: String, CodingKey { case mediaContainer = "MediaContainer" }
    enum MetadataKey: String, CodingKey {
        case metadata = "Metadata"
        case directory = "Directory"
    }
}
