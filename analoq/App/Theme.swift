import SwiftUI

enum TVTheme {
    // Neutral liquid-glass base with restrained yellow accents.
    static let accent = Color(red: 0.95, green: 0.76, blue: 0.18)
    static let accentStrong = Color(red: 1.00, green: 0.84, blue: 0.30)
    static let background = Color(red: 0.03, green: 0.04, blue: 0.05)
    static let backgroundTop = Color(red: 0.08, green: 0.09, blue: 0.11)
    static let surface = Color.white.opacity(0.10)
    static let surfaceRaised = Color.white.opacity(0.14)
    static let border = Color.white.opacity(0.22)
    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.70)
}

struct TVAppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [TVTheme.backgroundTop, TVTheme.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [Color.white.opacity(0.07), .clear],
                center: .topLeading,
                startRadius: 30,
                endRadius: 520
            )
            .blendMode(.plusLighter)
            .ignoresSafeArea()

            RadialGradient(
                colors: [Color.white.opacity(0.05), .clear],
                center: .bottomTrailing,
                startRadius: 60,
                endRadius: 620
            )
            .blendMode(.plusLighter)
            .ignoresSafeArea()
        }
    }
}

struct TVSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [TVTheme.surfaceRaised.opacity(0.82), TVTheme.surface.opacity(0.68)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.35), Color.white.opacity(0.09)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.black.opacity(0.20), lineWidth: 0.5)
                    .blur(radius: 1)
            )
            .shadow(color: Color.black.opacity(0.30), radius: 28, y: 12)
    }
}

extension View {
    func tvSurface(cornerRadius: CGFloat = 14) -> some View {
        modifier(TVSurface(cornerRadius: cornerRadius))
    }
}
