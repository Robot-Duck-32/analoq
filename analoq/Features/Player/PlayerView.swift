import SwiftUI
import AVFoundation

struct PlayerView: View {
    @ObservedObject var player: ChannelPlayer
    let channel: AnaloqChannel
    var onExit: () -> Void
    var onToggleGuide: () -> Void
    var onZapPrevious: () -> Void
    var onZapNext: () -> Void
    var commandsEnabled: Bool = true
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var didShowInitialOverlay = false
    @State private var fillScreen = false
    #if os(tvOS)
    @FocusState private var commandsFocused: Bool
    #endif
    #if os(iOS)
    @GestureState private var pinchValue: CGFloat = 1.0
    #endif

    var body: some View {
        ZStack {
            VideoPlayerLayer(player: player.player, fillScreen: fillScreen).ignoresSafeArea()

            if showControls || player.playbackError != nil {
                LinearGradient(
                    colors: [Color.black.opacity(0.16), .clear, Color.black.opacity(0.46)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if showControls || player.playbackError != nil {
                VStack(spacing: 16) {
                    Spacer()

                    if let message = player.playbackError {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(L10n.tr("playback.failed.title"), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(TVTheme.textPrimary)
                                .font(.headline)
                            Text(message)
                                .font(.callout)
                                .foregroundStyle(TVTheme.textPrimary)
                            Button(L10n.tr("common.retry")) { Task { await player.tune(to: channel) } }
                                .buttonStyle(.bordered)
                                .tint(.white)
                            Button(L10n.tr("common.close_playback")) { onExit() }
                                .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: 700, alignment: .leading)
                        .padding(20)
                        .tvSurface(cornerRadius: 14)
                        .padding(.horizontal, 28)
                    }

                    if player.playbackError == nil {
                        NowPlayingOverlay(player: player, channel: channel)
                            .padding(.horizontal, 28)
                            .padding(.bottom, 24)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { revealControls() }
        .onAppear {
            if !didShowInitialOverlay {
                revealControls()
                didShowInitialOverlay = true
            }
            #if os(tvOS)
            restoreCommandFocus()
            #endif
        }
        .onChange(of: player.isLoading) { _, isLoading in
            if !isLoading && showControls {
                scheduleAutoHide()
            }
        }
        .onChange(of: channel.id) { _, _ in
            revealControls()
            #if os(tvOS)
            restoreCommandFocus()
            #endif
        }
        .onChange(of: commandsEnabled) { _, enabled in
            if enabled {
                revealControls()
            } else {
                hideTask?.cancel()
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls = false
                }
            }
            #if os(tvOS)
            if enabled {
                restoreCommandFocus()
            } else {
                commandsFocused = false
            }
            #endif
        }
        #if os(iOS)
        .simultaneousGesture(
            MagnificationGesture()
                .updating($pinchValue) { value, state, _ in
                    state = value
                }
                .onEnded { value in
                    if value > 1.03 {
                        fillScreen = true
                    } else if value < 0.97 {
                        fillScreen = false
                    }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 36)
                .onEnded { value in
                    let x = value.translation.width
                    let y = value.translation.height
                    guard abs(x) > abs(y), abs(x) > 64 else { return }
                    if x < 0 { onZapNext() } else { onZapPrevious() }
                }
        )
        #endif
        .onDisappear {
            hideTask?.cancel()
            #if os(tvOS)
            commandsFocused = false
            #endif
        }
        #if os(tvOS)
        .focusable(commandsEnabled)
        .focused($commandsFocused)
        .onMoveCommand { direction in
            guard commandsEnabled else { return }
            switch direction {
            case .up:
                onZapPrevious()
            case .down:
                onZapNext()
            default:
                break
            }
        }
        .onPlayPauseCommand {
            guard commandsEnabled else { return }
            revealControls()
        }
        .onExitCommand {
            guard commandsEnabled else { return }
            onToggleGuide()
        }
        #endif
        .animation(.easeInOut(duration: 0.2), value: showControls)
    }

    private func revealControls() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard !player.isLoading, player.playbackError == nil else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) { showControls = false }
            }
        }
    }

    #if os(tvOS)
    private func restoreCommandFocus() {
        guard commandsEnabled else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard commandsEnabled else { return }
            commandsFocused = true
        }
    }
    #endif

}

struct NowPlayingOverlay: View {
    @ObservedObject var player: ChannelPlayer
    let channel: AnaloqChannel
    private let scheduler = ChannelScheduler()

    private var visibleCurrentItem: ScheduledItem? {
        if let current = player.currentItem {
            return current
        }
        return scheduler.currentItem(for: channel)
    }

    private var visibleNextItem: ScheduledItem? {
        if let next = player.nextItem {
            return next
        }
        if let current = visibleCurrentItem {
            return scheduler.currentItem(for: channel, at: current.endsAt.addingTimeInterval(0.1))
        }
        return scheduler.nextItem(for: channel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.tr("channel.short", channel.number))
                    .font(.caption.bold().monospaced())
                    .foregroundStyle(TVTheme.textSecondary)
                Text(channel.name)
                    .font(.caption)
                    .foregroundStyle(TVTheme.textSecondary)
                    .lineLimit(1)
            }

            if let current = visibleCurrentItem {
                Text(current.item.displayTitle)
                    .font(.headline)
                    .foregroundStyle(TVTheme.textPrimary)
                    .lineLimit(2)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(TVTheme.border.opacity(0.65))
                            .frame(height: 5)
                        Capsule()
                            .fill(TVTheme.accent)
                            .frame(
                                width: max(0, geo.size.width * min(max(player.progress, 0), 1)),
                                height: 5
                            )
                    }
                }
                .frame(height: 5)
                HStack(spacing: 6) {
                    Circle().fill(TVTheme.accent).frame(width: 5, height: 5)
                    Text(L10n.tr("player.plays_until", current.endsAt.formatted(date: .omitted, time: .shortened)))
                        .font(.caption)
                        .foregroundStyle(TVTheme.textSecondary)
                }

                if let next = visibleNextItem {
                    TVInlineSeparator()
                    HStack(spacing: 6) {
                        Text(L10n.tr("player.up_next"))
                            .font(.caption)
                            .foregroundStyle(TVTheme.textSecondary)
                        Text(next.item.displayTitle)
                            .font(.caption)
                            .foregroundStyle(TVTheme.textPrimary)
                            .lineLimit(1)
                    }
                }
            } else {
                Text(L10n.tr("player.program_data.loading"))
                    .font(.callout)
                    .foregroundStyle(TVTheme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .tvSurface(cornerRadius: 12)
    }
}

// MARK: – Info Bar
struct LiveInfoBar: View {
    @ObservedObject var player: ChannelPlayer
    let channel: AnaloqChannel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.tr("channel.short", channel.number))
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(TVTheme.textSecondary)
                Text(channel.name)
                    .font(.headline)
                    .foregroundStyle(TVTheme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(player.streamMode.description)
                    .font(.caption.monospaced())
                    .foregroundStyle(TVTheme.textSecondary)
            }

            if let current = player.currentItem {
                Text(current.item.displayTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(TVTheme.textPrimary)
                    .lineLimit(2)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(TVTheme.border.opacity(0.8)).frame(height: 6)
                        Capsule().fill(TVTheme.accent).frame(width: geo.size.width * player.progress, height: 6)
                    }
                }
                .frame(height: 6)
                Text(L10n.tr("player.plays_until", current.endsAt.formatted(date: .omitted, time: .shortened)))
                    .font(.caption)
                    .foregroundStyle(TVTheme.textSecondary)
            } else {
                Text(L10n.tr("player.program_data.loading"))
                    .font(.callout)
                    .foregroundStyle(TVTheme.textSecondary)
            }

            if let next = player.nextItem {
                TVInlineSeparator()
                HStack(spacing: 8) {
                    Text(L10n.tr("player.up_next"))
                        .font(.caption)
                        .foregroundStyle(TVTheme.textSecondary)
                    Text(next.item.displayTitle)
                        .font(.callout)
                        .foregroundStyle(TVTheme.textPrimary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .tvSurface(cornerRadius: 14)
    }
}

private struct TVInlineSeparator: View {
    var body: some View {
        Rectangle()
            .fill(TVTheme.border.opacity(0.9))
            .frame(maxWidth: .infinity)
            .frame(height: 1)
    }
}

// MARK: – AVPlayerLayer Bridge
struct VideoPlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    let fillScreen: Bool

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.updateDisplayMode(fillScreen: fillScreen)
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
        uiView.updateDisplayMode(fillScreen: fillScreen)
    }
}

class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        isUserInteractionEnabled = false
    }

    func updateDisplayMode(fillScreen: Bool) {
        playerLayer.setAffineTransform(.identity)
        playerLayer.videoGravity = fillScreen ? .resizeAspectFill : .resizeAspect
    }
}

// MARK: – Main View
struct MainView: View {
    @EnvironmentObject var store: ChannelStore
    @EnvironmentObject var player: ChannelPlayer
    @State private var showEPG = false
    @State private var didAutoTune = false
    @State private var tuneTask: Task<Void, Never>?
    @State private var pendingChannelID: String?

    var body: some View {
        ZStack {
            if let channel = player.currentChannel {
                PlayerView(
                    player: player,
                    channel: channel,
                    onExit: exitPlayback,
                    onToggleGuide: { withAnimation { showEPG = true } },
                    onZapPrevious: { zap(by: -1) },
                    onZapNext: { zap(by: 1) },
                    commandsEnabled: !showEPG
                )
                .allowsHitTesting(!showEPG)
                .ignoresSafeArea()
            } else {
                Color.black
                    .ignoresSafeArea()
            }
            if showEPG {
                EPGView(
                    store: store,
                    player: player,
                    onTuneChannel: { tune($0) },
                    onClose: { withAnimation { showEPG = false } }
                )
                    .ignoresSafeArea()
                    .transition(.move(edge: .bottom))
            }
        }
        .task(id: store.channels.count) {
            await autoStartPlaybackIfNeeded()
        }
        .animation(.spring(duration: 0.3), value: showEPG)
    }

    private func tune(_ channel: AnaloqChannel, force: Bool = false) {
        withAnimation { showEPG = false }
        let target = store.channels.first(where: { $0.id == channel.id }) ?? channel
        pendingChannelID = target.id
        tuneTask?.cancel()
        tuneTask = Task {
            await player.tune(to: target, force: force)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if pendingChannelID == target.id {
                    pendingChannelID = nil
                }
            }
        }
    }

    private func zap(by step: Int) {
        let channels = store.channels
        guard !channels.isEmpty else { return }

        let anchorID = pendingChannelID ?? player.currentChannel?.id
        guard let anchorID,
              let currentIndex = channels.firstIndex(where: { $0.id == anchorID }) else {
            tune(channels[0])
            return
        }
        let nextIndex = (currentIndex + step + channels.count) % channels.count
        tune(channels[nextIndex])
    }

    private func exitPlayback() {
        withAnimation { showEPG = false }
        tuneTask?.cancel()
        tuneTask = nil
        pendingChannelID = nil
        player.stopPlayback()
    }

    private func autoStartPlaybackIfNeeded() async {
        guard !didAutoTune, player.currentChannel == nil, let first = store.channels.first else { return }
        didAutoTune = true
        tune(first)
    }
}
