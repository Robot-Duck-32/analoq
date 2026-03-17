import SwiftUI

struct LoginView: View {
    @StateObject private var viewModel: LoginViewModel
    var onLogin: (String) -> Void

    init(viewModel: LoginViewModel, onLogin: @escaping (String) -> Void) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.onLogin = onLogin
    }

    var body: some View {
        GeometryReader { geo in
            let cardWidth = min(geo.size.width * 0.46, 560)
            let qrSize = min(cardWidth * 0.62, 320)

            ZStack {
                TVAppBackground()

                VStack {
                    Spacer(minLength: 36)
                    VStack(spacing: 20) {
                        Text("analoq")
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .foregroundStyle(TVTheme.textPrimary)

                        Text(L10n.tr("auth.scan_qr"))
                            .font(.subheadline)
                            .foregroundStyle(TVTheme.textSecondary)

                        qrCard(size: qrSize)

                        statusView
                    }
                    .frame(width: cardWidth)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 34)
                    .tvSurface(cornerRadius: 24)
                    Spacer(minLength: 36)
                }
            }
        }
        .task {
            viewModel.onSuccess = onLogin
            await viewModel.startLogin()
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch viewModel.state {
        case .polling:
            HStack(spacing: 8) {
                ProgressView().tint(TVTheme.accent)
                Text(L10n.tr("auth.waiting_confirmation"))
                    .font(.caption)
                    .foregroundStyle(TVTheme.textSecondary)
            }
        case .error(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.red.opacity(0.9))
        default:
            EmptyView()
        }
    }

    private func qrCard(size: CGFloat) -> some View {
        VStack {
            if let img = viewModel.qrCodeImage {
                Image(img, scale: 1, label: Text(L10n.tr("auth.qr.accessibility")))
                    .interpolation(.none).resizable()
                    .frame(width: size, height: size)
                    .padding(12)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            } else {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: size + 24, height: size + 24)
                    .overlay(ProgressView().tint(TVTheme.accent))
            }
        }
    }
}

struct LaunchView: View {
    var body: some View {
        ZStack {
            TVAppBackground()
            VStack(spacing: 16) {
                Text("ANALOQ").font(.system(size: 32, weight: .bold, design: .monospaced))
                    .foregroundStyle(TVTheme.accentStrong)
                ProgressView().tint(TVTheme.accent)
            }
        }
    }
}
