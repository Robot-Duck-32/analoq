import SwiftUI

struct ServerSelectionView: View {
    @ObservedObject var vm: ServerSelectionViewModel
    var onSelected: (AnaloqServer) -> Void
    @FocusState private var focusedServerID: String?

    var body: some View {
        ZStack {
            TVAppBackground()
            switch vm.state {
            case .loading:
                VStack(spacing: 20) {
                    ProgressView().tint(TVTheme.accent).scaleEffect(1.5)
                    Text(L10n.tr("server.searching"))
                        .font(.headline)
                        .foregroundStyle(TVTheme.textSecondary)
                }
                .padding(26)
                .tvSurface(cornerRadius: 16)
            case .empty:
                ContentUnavailableView(L10n.tr("server.empty.title"), systemImage: "server.rack",
                    description: Text(L10n.tr("server.empty.description")))
            case .error(let msg):
                ContentUnavailableView(L10n.tr("common.error"), systemImage: "exclamationmark.triangle",
                    description: Text(msg))
            case .loaded(let servers):
                VStack(alignment: .leading, spacing: 40) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("server.selection.title"))
                            .font(.system(size: 40, weight: .bold))
                            .foregroundStyle(TVTheme.textPrimary)
                        Text(L10n.tr("server.selection.subtitle"))
                            .font(.callout)
                            .foregroundStyle(TVTheme.textSecondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 400))], spacing: 20) {
                        ForEach(servers) { server in
                            Button {
                                guard server.isReachable else { return }
                                vm.select(server)
                                onSelected(server)
                            } label: {
                                ServerCard(
                                    server: server,
                                    isFocused: focusedServerID == server.id
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(!server.isReachable)
                            .focused($focusedServerID, equals: server.id)
                        }
                    }
                }
                .padding(56)
            }
        }
        .task { await vm.load() }
    }
}

struct ServerCard: View {
    let server: AnaloqServer
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: "server.rack")
                .font(.system(size: 36))
                .foregroundStyle(server.isReachable ? TVTheme.accent : TVTheme.textSecondary)
                .frame(width: 60)
            VStack(alignment: .leading, spacing: 6) {
                Text(server.name).font(.headline).foregroundStyle(TVTheme.textPrimary)
                if let conn = server.preferredConnection {
                    ConnectionBadge(connection: conn)
                } else {
                    Label(L10n.tr("server.unreachable"), systemImage: "xmark.circle")
                        .font(.caption).foregroundStyle(.red.opacity(0.9))
                }
                Text(L10n.tr("server.version", server.productVersion)).font(.caption2).foregroundStyle(TVTheme.textSecondary)
            }
            Spacer()
            if server.isReachable { Image(systemName: "chevron.right").foregroundStyle(TVTheme.textSecondary) }
        }
        .padding(24)
        .tvSurface(cornerRadius: 16)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isFocused ? TVTheme.accentStrong : Color.clear, lineWidth: 2)
        )
        .opacity(server.isReachable ? 1 : 0.55)
        .scaleEffect(isFocused ? 1.01 : 1)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

struct ConnectionBadge: View {
    let connection: AnaloqConnection
    var label: String {
        connection.local && !connection.relay
            ? L10n.tr("connection.local")
            : connection.relay
                ? L10n.tr("connection.relay")
                : L10n.tr("connection.remote")
    }
    var icon: String  { connection.local ? "wifi" : "globe" }
    var color: Color  { connection.local && !connection.relay ? .green : TVTheme.accentStrong }
    var body: some View {
        Label(label, systemImage: icon).font(.caption.bold()).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.15)).clipShape(Capsule())
    }
}
