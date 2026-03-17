import SwiftUI

struct LibrarySelectionView: View {
    @ObservedObject var store: LibrarySelectionStore
    var onConfirm: () -> Void
    @FocusState private var focusedTarget: FocusTarget?
    @State private var lastFocusedLibraryID: String?

    private enum FocusTarget: Hashable {
        case library(String)
        case continueButton
    }

    var body: some View {
        ZStack {
            TVAppBackground()
            VStack(spacing: 48) {
                VStack(spacing: 12) {
                    Image(systemName: "film.stack").font(.system(size: 46)).foregroundStyle(TVTheme.accent)
                    Text(L10n.tr("library.selection.title"))
                        .font(.system(size: 34, weight: .bold)).foregroundStyle(TVTheme.textPrimary)
                    Text(L10n.tr("library.selection.subtitle"))
                        .font(.callout).foregroundStyle(TVTheme.textSecondary)
                }

                switch store.loadState {
                case .loading: ProgressView().tint(TVTheme.accent)
                case .error(let msg): Label(msg, systemImage: "exclamationmark.circle").foregroundStyle(.red.opacity(0.9))
                case .ready, .idle:
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 20) {
                            ForEach(store.libraries) { library in
                                Button {
                                    store.toggle(library)
                                } label: {
                                    LibraryCard(
                                        library: library,
                                        isSelected: store.selection.selectedIDs.contains(library.id),
                                        isFocused: focusedTarget == .library(library.id)
                                    )
                                }
                                .buttonStyle(.plain)
                                .focused($focusedTarget, equals: .library(library.id))
                            }
                        }
                    }
                }

                VStack(spacing: 16) {
                    Button { store.save(); onConfirm() } label: {
                        HStack { Text(L10n.tr("common.continue")); Image(systemName: "arrow.right") }.frame(width: 280)
                    }
                    .buttonStyle(.borderedProminent).tint(TVTheme.accent)
                    .disabled(!store.isValid).font(.headline)
                    .focused($focusedTarget, equals: .continueButton)

                    if store.isValid {
                        Text(L10n.tr("library.selection.collections_from", store.selectedLibraries.map(\.title).joined(separator: " + ")))
                            .font(.caption).foregroundStyle(TVTheme.textSecondary)
                    }
                }
            }
            .padding(60)
        }
        .task { await store.load() }
        #if os(tvOS)
        .onAppear { applyDefaultFocusIfNeeded() }
        .onMoveCommand(perform: handleMoveCommand)
        .onChange(of: focusedTarget) { _, target in
            guard case .library(let libraryID) = target else { return }
            lastFocusedLibraryID = libraryID
        }
        .onChange(of: store.libraries.map(\.id)) { _, _ in
            applyDefaultFocusIfNeeded()
        }
        .onChange(of: store.isValid) { _, isValid in
            if !isValid, focusedTarget == .continueButton, let libraryID = preferredLibraryFocusID() {
                focusedTarget = .library(libraryID)
            }
        }
        #endif
    }

    #if os(tvOS)
    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        switch direction {
        case .down:
            guard store.isValid else { return }
            if case .library = focusedTarget {
                focusedTarget = .continueButton
            }
        case .up:
            if focusedTarget == .continueButton, let libraryID = preferredLibraryFocusID() {
                focusedTarget = .library(libraryID)
            }
        default:
            break
        }
    }

    private func applyDefaultFocusIfNeeded() {
        guard focusedTarget == nil, let libraryID = preferredLibraryFocusID() else { return }
        focusedTarget = .library(libraryID)
    }

    private func preferredLibraryFocusID() -> String? {
        if let lastFocusedLibraryID, store.libraries.contains(where: { $0.id == lastFocusedLibraryID }) {
            return lastFocusedLibraryID
        }
        if let selectedLibraryID = store.selectedLibraries.first?.id {
            return selectedLibraryID
        }
        return store.libraries.first?.id
    }
    #endif
}

struct LibraryCard: View {
    let library: AnaloqLibrary
    let isSelected: Bool
    let isFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(isSelected ? TVTheme.accent : TVTheme.surfaceRaised).frame(width: 80, height: 80)
                Image(systemName: library.type.icon).font(.system(size: 32))
                    .foregroundStyle(isSelected ? .black : .white)
            }
            .scaleEffect(isFocused ? 1.08 : 1)
            VStack(spacing: 6) {
                Text(library.title).font(.headline).foregroundStyle(TVTheme.textPrimary)
                Text(library.type.label).font(.caption).foregroundStyle(TVTheme.textSecondary)
                Text(L10n.tr(L10n.pluralKey("item.count", count: library.itemCount), library.itemCount)).font(.caption2).foregroundStyle(TVTheme.textSecondary.opacity(0.8))
            }
            Label(isSelected ? L10n.tr("library.state.active") : L10n.tr("library.state.inactive"), systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.caption.bold())
                .foregroundStyle(isSelected ? TVTheme.accentStrong : TVTheme.textSecondary)
        }
        .padding(28).frame(width: 220)
        .tvSurface(cornerRadius: 20)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(isSelected ? TVTheme.accentStrong : (isFocused ? TVTheme.border : Color.clear), lineWidth: 2)
        )
        .shadow(color: isSelected ? TVTheme.accent.opacity(0.25) : .clear, radius: 20)
        .animation(.spring(duration: 0.2), value: isSelected)
        .animation(.spring(duration: 0.2), value: isFocused)
    }
}
