import SwiftUI

struct ChannelGridView: View {
    @ObservedObject var store: ChannelStore
    var onChannelSelected: (AnaloqChannel) -> Void
    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 20)]
    @FocusState private var focusedChannelID: String?

    var body: some View {
        ZStack {
            TVAppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("guide.title"))
                                .font(.system(size: 36, weight: .bold))
                                .foregroundStyle(TVTheme.textPrimary)
                            Text(L10n.tr("channel.grid.subtitle"))
                                .foregroundStyle(TVTheme.textSecondary)
                        }
                        Spacer()
                        Text(L10n.tr(L10n.pluralKey("channel.count", count: store.channels.count), store.channels.count))
                            .font(.caption.monospaced())
                            .foregroundStyle(TVTheme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(TVTheme.surfaceRaised.opacity(0.9), in: Capsule())
                    }

                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(store.channels) { channel in
                            Button {
                                onChannelSelected(channel)
                            } label: {
                                ChannelTile(
                                    channel: channel,
                                    artworkURL: store.artworkURL(for: channel),
                                    loadState: store.itemLoadStates[channel.id] ?? .idle,
                                    isFocused: focusedChannelID == channel.id
                                )
                            }
                            .buttonStyle(.plain)
                            .focused($focusedChannelID, equals: channel.id)
                        }
                    }
                }
                .padding(34)
            }
        }
    }
}

struct ChannelTile: View {
    let channel: AnaloqChannel
    let artworkURL: URL?
    let loadState: ChannelStore.LoadState
    let isFocused: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: artworkURL) { phase in
                switch phase {
                    case .success(let img): img.resizable().aspectRatio(16/9, contentMode: .fill)
                    default:
                    Rectangle().fill(TVTheme.surface.opacity(0.9))
                        .overlay(Image(systemName: "play.tv").font(.system(size: 40)).foregroundStyle(TVTheme.textSecondary))
                }
            }
            .aspectRatio(16/9, contentMode: .fit).clipped()

            LinearGradient(
                colors: [.clear, Color.black.opacity(0.86)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("channel.short", channel.number))
                    .font(.caption.bold().monospaced())
                    .foregroundStyle(TVTheme.accentStrong)
                Text(channel.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    switch loadState {
                    case .loading:
                        ProgressView().scaleEffect(0.6).tint(TVTheme.accent)
                        Text(L10n.tr("common.loading"))
                    case .ready:
                        Image(systemName: "film.stack")
                        Text(L10n.tr(L10n.pluralKey("item.count", count: channel.items.count), channel.items.count))
                    case .error:
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                        Text(L10n.tr("common.error"))
                    case .idle:
                        Image(systemName: "film.stack")
                        Text(L10n.tr(L10n.pluralKey("item.count", count: channel.itemCount), channel.itemCount))
                    }
                }
                .font(.caption).foregroundStyle(Color.white.opacity(0.78))
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isFocused ? TVTheme.accentStrong : TVTheme.border.opacity(0.7), lineWidth: isFocused ? 3 : 1)
        )
        .scaleEffect(isFocused ? 1.03 : 1.0)
        .shadow(color: isFocused ? TVTheme.accent.opacity(0.4) : .clear, radius: 20)
        .animation(.spring(duration: 0.2), value: isFocused)
    }
}
