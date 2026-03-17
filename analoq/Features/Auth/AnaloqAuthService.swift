import Foundation
import Security

actor AnaloqAuthService {

    private let clientID: String
    private let appName = "analoq"
    private let appVersion = "1.0"
    private let keychainService = AnaloqProtocol.keychainTokenService
    private let keychainAccount = "default"
    #if os(tvOS)
    private let platform = "tvOS"
    #elseif os(iOS)
    private let platform = "iOS"
    #else
    private let platform = "Apple"
    #endif

    init() {
        self.clientID = UserDefaults.standard.string(forKey: AnaloqProtocol.clientIDUserDefaultsKey)
            ?? UserDefaults.standard.string(forKey: AnaloqProtocol.legacyClientIDUserDefaultsKey)
            ?? {
            let id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: AnaloqProtocol.clientIDUserDefaultsKey)
            return id
        }()
    }

    private var headers: [String: String] {
        [
            AnaloqProtocol.clientIdentifierHeader: clientID,
            AnaloqProtocol.productHeader: appName,
            AnaloqProtocol.versionHeader: appVersion,
            AnaloqProtocol.platformHeader: platform,
            AnaloqProtocol.deviceHeader: platform,
            AnaloqProtocol.deviceNameHeader: appName,
            AnaloqProtocol.modelHeader: platform,
            "Accept": "application/json"
        ]
    }

    func requestPin() async throws -> AnaloqPin {
        var components = URLComponents(string: AnaloqProtocol.apiBaseURL + "/api/v2/pins")!
        components.queryItems = [URLQueryItem(name: "strong", value: "true")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = headers
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw apiError(from: data, fallbackStatus: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(AnaloqPin.self, from: data)
        } catch {
            throw AuthError.invalidResponse
        }
    }

    func authPageURL(for pin: AnaloqPin) -> URL? {
        var auth = URLComponents(string: AnaloqProtocol.webAuthURL)!
        var query = URLComponents()
        query.queryItems = [
            URLQueryItem(name: "clientID", value: clientID),
            URLQueryItem(name: "code", value: pin.code),
            URLQueryItem(name: "context[device][product]", value: appName),
            URLQueryItem(name: "context[device][version]", value: appVersion),
            URLQueryItem(name: "context[device][platform]", value: platform),
            URLQueryItem(name: "context[device][device]", value: platform),
        ]
        guard let q = query.percentEncodedQuery else { return nil }
        auth.fragment = "?\(q)"
        return auth.url
    }

    func waitForAuth(pin: AnaloqPin) async throws -> String {
        let url = URL(string: AnaloqProtocol.apiBaseURL + "/api/v2/pins/\(pin.id)")!
        for _ in 0..<150 {
            guard !Task.isCancelled else { throw AuthError.cancelled }
            try await Task.sleep(for: .seconds(2))
            var request = URLRequest(url: url)
            request.allHTTPHeaderFields = headers
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw apiError(from: data, fallbackStatus: http.statusCode)
            }
            let result: AnaloqPin
            do {
                result = try JSONDecoder().decode(AnaloqPin.self, from: data)
            } catch {
                throw AuthError.invalidResponse
            }
            if let token = result.authToken {
                try saveToken(token)
                return token
            }
        }
        throw AuthError.timeout
    }

    private func apiError(from data: Data, fallbackStatus: Int) -> AuthError {
        if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data),
           let first = envelope.errors.first {
            return .api(status: first.status ?? fallbackStatus, message: first.message)
        }
        return .api(status: fallbackStatus, message: nil)
    }

    func saveToken(_ token: String) throws {
        let data = token.data(using: .utf8)!
        let query: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    keychainService,
            kSecAttrAccount:    keychainAccount,
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw AuthError.keychainError(status) }
    }

    func loadToken() -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData:  true
        ]
        var result: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &result)
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func logout() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: – Models
struct AnaloqPin: Decodable {
    let id: Int
    let code: String
    let authToken: String?

    enum CodingKeys: String, CodingKey {
        case id
        case code
        case authToken
        case auth_token
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let intID = try? c.decode(Int.self, forKey: .id) {
            id = intID
        } else if let stringID = try? c.decode(String.self, forKey: .id),
                  let intID = Int(stringID) {
            id = intID
        } else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Invalid pin id")
        }
        code = try c.decode(String.self, forKey: .code)
        authToken = (try? c.decode(String.self, forKey: .authToken))
            ?? (try? c.decode(String.self, forKey: .auth_token))
    }
}

enum AuthError: Error, LocalizedError {
    case timeout, cancelled, keychainError(OSStatus)
    case invalidResponse
    case api(status: Int, message: String?)
    var errorDescription: String? {
        switch self {
        case .timeout:              return L10n.tr("auth.timeout")
        case .cancelled:            return L10n.tr("auth.cancelled")
        case .keychainError(let s): return L10n.tr("auth.keychain_error", Int(s))
        case .invalidResponse:      return L10n.tr("auth.invalid_response")
        case .api(let status, let message):
            if status == 401 {
                return L10n.tr("auth.invalid_or_expired")
            }
            if let message, !message.isEmpty {
                return L10n.tr("error.server_api.with_message", status, message)
            }
            return L10n.tr("error.server_api.without_message", status)
        }
    }
}

private struct APIErrorEnvelope: Decodable {
    let errors: [APIErrorDetail]
}

private struct APIErrorDetail: Decodable {
    let code: Int?
    let message: String?
    let status: Int?
}
