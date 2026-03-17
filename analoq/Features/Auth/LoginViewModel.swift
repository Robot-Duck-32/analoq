import Foundation
import CoreGraphics

@MainActor
class LoginViewModel: ObservableObject {

    enum LoginState { case idle, polling, success, error(String) }

    @Published var state: LoginState = .idle
    @Published var pin: AnaloqPin?
    @Published var qrCodeImage: CGImage?
    @Published var pinExpiry: Date?
    @Published var authURL: URL?

    private let auth: AnaloqAuthService
    private var pollingTask: Task<Void, Never>?
    var onSuccess: ((String) -> Void)?

    init(auth: AnaloqAuthService) { self.auth = auth }

    func startLogin() async {
        do {
            state = .polling
            let pin = try await auth.requestPin()
            self.pin = pin
            authURL = await auth.authPageURL(for: pin)
            let qrURL = authURL?.absoluteString ?? "\(AnaloqProtocol.manualLinkBaseURL)\(pin.code)"
            qrCodeImage = QRCodeGenerator.generate(from: qrURL)
            pinExpiry = Date().addingTimeInterval(5 * 60)

            pollingTask = Task {
                do {
                    let token = try await auth.waitForAuth(pin: pin)
                    state = .success
                    onSuccess?(token)
                } catch {
                    state = .error(error.localizedDescription)
                }
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func refresh() async {
        pollingTask?.cancel()
        await startLogin()
    }

    deinit { pollingTask?.cancel() }
}
