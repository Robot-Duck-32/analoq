import Foundation
import AVFoundation

@MainActor
class ChannelPlayer: ObservableObject {

    @Published var currentChannel: AnaloqChannel?
    @Published var currentItem: ScheduledItem?
    @Published var nextItem: ScheduledItem?
    @Published var isLoading: Bool = false
    @Published var progress: Double = 0
    @Published var streamMode: StreamMode = .directPlay
    @Published var playbackError: String?

    let player = AVPlayer()

    private let scheduler = ChannelScheduler()
    private let service: CollectionService
    private let streamService: StreamService
    private var progressTimer: Timer?
    private var endObserver: Any?
    private var stalledObserver: Any?
    private var failedToEndObserver: Any?
    private var loadedScheduledItem: ScheduledItem?
    private var loadedItemExpectedEndDate: Date?
    private var isAutoAdvancing = false
    private var activeTuneID = UUID()
    private var lastRecoveryDate = Date.distantPast
    private var lastPlaybackProgressDate = Date.now
    private var lastObservedPlaybackSecond: Double?
    private var recoveryAttemptCount = 0
    private let maxRecoveryAttempts = 3
    private var nextStreamPreference: StreamRecoveryPreference = .defaultPath

    init(service: CollectionService, streamService: StreamService) {
        self.service = service
        self.streamService = streamService
        #if os(tvOS)
        player.automaticallyWaitsToMinimizeStalling = false
        #else
        player.automaticallyWaitsToMinimizeStalling = true
        #endif
        player.actionAtItemEnd = .pause
        player.allowsExternalPlayback = false
        setupAudioSession()
        observePlaybackStalls()
        observePlaybackFailures()
    }

    func tune(to channel: AnaloqChannel, force: Bool = false) async {
        await startPlayback(for: channel, force: force, referenceDate: .now, autoAdvance: false)
    }

    private func startPlayback(
        for channel: AnaloqChannel,
        force: Bool,
        referenceDate: Date,
        autoAdvance: Bool
    ) async {
        guard force || channel.id != currentChannel?.id || playbackError != nil else { return }
        let tuneID = UUID()
        activeTuneID = tuneID
        isAutoAdvancing = autoAdvance
        if !autoAdvance {
            nextStreamPreference = .defaultPath
        }
        isLoading = true
        playbackError = nil
        loadedScheduledItem = nil
        loadedItemExpectedEndDate = nil
        resetPlaybackProgressTracking()
        stopProgressTimer()
        player.pause()
        player.replaceCurrentItem(with: nil)
        var tunedChannel = channel
        currentChannel = tunedChannel
        currentItem = nil
        nextItem = nil

        if tunedChannel.items.isEmpty,
           let fetchedItems = try? await service.fetchItems(for: channel),
           !fetchedItems.isEmpty {
            guard activeTuneID == tuneID else { return }
            tunedChannel.items = fetchedItems
        }

        guard activeTuneID == tuneID else { return }
        currentChannel = tunedChannel

        guard let scheduled = scheduler.currentItem(for: tunedChannel, at: referenceDate) else {
            playbackError = L10n.tr("player.no_playable_content")
            isLoading = false
            isAutoAdvancing = false
            return
        }

        currentItem = scheduled
        nextItem = scheduler.nextItem(for: tunedChannel, at: referenceDate)
        let durationForProgress = max(scheduled.item.durationSeconds, 1)
        progress = min(max(scheduled.startOffset / durationForProgress, 0), 1)

        do {
            try await playScheduledItem(scheduled, in: tunedChannel, tuneID: tuneID)
        } catch {
            if error is CancellationError || Task.isCancelled || activeTuneID != tuneID {
                return
            }
            playbackError = error.localizedDescription
            isLoading = false
            isAutoAdvancing = false
        }
    }

    func stopPlayback() {
        activeTuneID = UUID()
        stopProgressTimer()
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs) }
        endObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        loadedScheduledItem = nil
        loadedItemExpectedEndDate = nil
        isAutoAdvancing = false
        recoveryAttemptCount = 0
        nextStreamPreference = .defaultPath
        resetPlaybackProgressTracking()
        currentItem = nil
        nextItem = nil
        currentChannel = nil
        isLoading = false
        playbackError = nil
    }

    private func observePlaybackStalls() {
        if let obs = stalledObserver { NotificationCenter.default.removeObserver(obs) }
        stalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.isLoading, !self.isAutoAdvancing else { return }
                guard let current = self.player.currentItem else { return }
                guard notification.object as AnyObject === current else { return }
                guard let channel = self.currentChannel else { return }
                await self.attemptStallRecovery(for: channel)
            }
        }
    }

    private func observePlaybackFailures() {
        if let obs = failedToEndObserver { NotificationCenter.default.removeObserver(obs) }
        failedToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.isLoading, !self.isAutoAdvancing else { return }
                guard let current = self.player.currentItem else { return }
                guard notification.object as AnyObject === current else { return }
                guard let channel = self.currentChannel else { return }
                await self.attemptStallRecovery(for: channel)
            }
        }
    }

    private func attemptStallRecovery(for channel: AnaloqChannel) async {
        guard Date.now.timeIntervalSince(lastRecoveryDate) > 4 else { return }
        lastRecoveryDate = Date.now

        let beforeRecoveryTime = currentPlaybackSecond()
        isLoading = true
        player.play()
        try? await Task.sleep(for: .milliseconds(900))
        guard currentChannel?.id == channel.id else {
            isLoading = false
            return
        }

        let activelyPlaying = isPlaybackAdvancing(since: beforeRecoveryTime)
        if activelyPlaying {
            isLoading = false
            recoveryAttemptCount = 0
            lastPlaybackProgressDate = .now
            return
        }

        guard recoveryAttemptCount < maxRecoveryAttempts else {
            playbackError = L10n.tr("player.stream_interrupted")
            isLoading = false
            recoveryAttemptCount = 0
            return
        }

        nextStreamPreference = recoveryPreference(for: streamMode, attempt: recoveryAttemptCount)
        recoveryAttemptCount += 1
        await startPlayback(
            for: channel,
            force: true,
            referenceDate: Date.now.addingTimeInterval(0.15),
            autoAdvance: true
        )
        if playbackError == nil {
            recoveryAttemptCount = 0
        }
    }

    private func recoveryPreference(for mode: StreamMode, attempt: Int) -> StreamRecoveryPreference {
        if attempt == 0 {
            switch mode {
            case .directPlay, .directStream:
                return .preferTranscode(.defaultTranscodeQuality)
            case .transcode(let quality):
                return .preferTranscode(quality)
            }
        }
        return .preferTranscode(recoveryFallbackQuality(for: mode))
    }

    private func recoveryFallbackQuality(for mode: StreamMode) -> VideoQuality {
        switch mode {
        case .directPlay, .directStream:
            return .defaultTranscodeQuality
        case .transcode(let quality):
            return quality.fallbackQuality ?? quality
        }
    }

    private func recordSuccessfulPlaybackStart() {
        recoveryAttemptCount = 0
        playbackError = nil
        nextStreamPreference = .defaultPath
    }

    private func observeItemEnd(
        for playerItem: AVPlayerItem,
        scheduled: ScheduledItem,
        in channel: AnaloqChannel,
        tuneID: UUID
    ) {
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.activeTuneID == tuneID else { return }
                guard self.currentChannel?.id == channel.id else { return }
                await self.advanceToNextItem(after: scheduled, in: channel, tuneID: tuneID)
            }
        }
    }

    private func advanceToNextItem(
        after scheduled: ScheduledItem,
        in channel: AnaloqChannel,
        tuneID: UUID
    ) async {
        guard activeTuneID == tuneID else { return }
        guard currentChannel?.id == channel.id else { return }
        let referenceDate = max(Date.now, scheduled.endsAt).addingTimeInterval(0.15)
        await startPlayback(for: channel, force: true, referenceDate: referenceDate, autoAdvance: true)
    }

    private func startProgressTimer(for channel: AnaloqChannel, tuneID: UUID) {
        stopProgressTimer()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.activeTuneID == tuneID else { return }
                guard self.currentChannel?.id == channel.id else { return }
                let now = Date.now

                if !self.isAutoAdvancing,
                   let currentPlayerItem = self.player.currentItem,
                   self.hasReachedPlaybackEnd(for: currentPlayerItem) {
                    await self.startPlayback(
                        for: channel,
                        force: true,
                        referenceDate: now.addingTimeInterval(0.15),
                        autoAdvance: true
                    )
                    return
                }

                if let currentPlayerItem = self.player.currentItem {
                    self.updatePlaybackProgress(now: now, playerItem: currentPlayerItem)
                    if !self.isLoading,
                       !self.isAutoAdvancing,
                       self.playbackError == nil,
                       self.isPlaybackLikelyStuck(now: now, playerItem: currentPlayerItem) {
                        await self.attemptStallRecovery(for: channel)
                        return
                    }
                }

                if let loaded = self.loadedScheduledItem,
                   !self.isAutoAdvancing,
                   now.timeIntervalSince(self.loadedItemExpectedEndDate ?? loaded.endsAt) > 0.35 {
                    await self.startPlayback(
                        for: channel,
                        force: true,
                        referenceDate: now.addingTimeInterval(0.15),
                        autoAdvance: true
                    )
                    return
                }

                guard let scheduled = self.scheduler.currentItem(for: channel, at: now) else {
                    self.currentItem = nil
                    self.nextItem = nil
                    self.progress = 0
                    return
                }

                self.currentItem = scheduled
                self.nextItem = self.scheduler.nextItem(for: channel, at: now)
                let duration = max(scheduled.item.durationSeconds, 1)
                self.progress = min(max(scheduled.startOffset / duration, 0), 1)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() { progressTimer?.invalidate(); progressTimer = nil; progress = 0 }

    private func playScheduledItem(
        _ scheduled: ScheduledItem,
        in channel: AnaloqChannel,
        tuneID: UUID
    ) async throws {
        var stream = try await initialStreamResult(for: scheduled.item, playbackOffset: scheduled.startOffset)
        guard activeTuneID == tuneID else { throw CancellationError() }
        streamMode = stream.mode

        let playerItem: AVPlayerItem
        do {
            playerItem = try await createReadyPlayerItem(from: stream)
        } catch {
            guard activeTuneID == tuneID else { throw CancellationError() }
            stream = try await fallbackStreamResult(
                from: stream,
                for: scheduled.item,
                playbackOffset: scheduled.startOffset
            )
            guard activeTuneID == tuneID else { throw CancellationError() }
            streamMode = stream.mode
            playerItem = try await createReadyPlayerItem(from: stream)
        }

        guard activeTuneID == tuneID else { throw CancellationError() }
        loadedScheduledItem = scheduled
        observeItemEnd(for: playerItem, scheduled: scheduled, in: channel, tuneID: tuneID)

        loadedItemExpectedEndDate = resolvedPlaybackEndDate(for: scheduled, playerItem: playerItem)
        lastObservedPlaybackSecond = finitePlaybackSecond(for: playerItem)
        lastPlaybackProgressDate = .now
        #if os(tvOS)
        player.playImmediately(atRate: 1.0)
        #else
        player.play()
        #endif
        isLoading = false
        isAutoAdvancing = false
        recordSuccessfulPlaybackStart()
        startProgressTimer(for: channel, tuneID: tuneID)
    }

    private func resolvedPlaybackEndDate(for scheduled: ScheduledItem, playerItem: AVPlayerItem) -> Date {
        let duration = CMTimeGetSeconds(playerItem.duration)
        let currentTime = CMTimeGetSeconds(playerItem.currentTime())
        guard duration.isFinite, currentTime.isFinite, duration > 0 else { return scheduled.endsAt }

        let remaining = max(duration - currentTime, 0.2)
        return Date.now.addingTimeInterval(remaining)
    }

    private func hasReachedPlaybackEnd(for playerItem: AVPlayerItem) -> Bool {
        guard player.rate < 0.01 else { return false }
        guard playerItem.status == .readyToPlay else { return false }

        let duration = CMTimeGetSeconds(playerItem.duration)
        let currentTime = CMTimeGetSeconds(playerItem.currentTime())
        guard duration.isFinite, currentTime.isFinite, duration > 0 else { return false }

        return duration - currentTime <= 0.5
    }

    private func initialStreamResult(for item: AnaloqItem, playbackOffset: TimeInterval) async throws -> StreamResult {
        let preference = nextStreamPreference
        nextStreamPreference = .defaultPath

        switch preference {
        case .defaultPath:
            return try await streamService.streamURL(
                for: item,
                preferDirect: true,
                playbackOffset: playbackOffset
            )
        case .preferTranscode(let quality):
            return try await streamService.streamURL(
                for: item,
                preferTranscode: true,
                preferredQuality: quality,
                playbackOffset: playbackOffset
            )
        }
    }

    private func fallbackStreamResult(
        from stream: StreamResult,
        for item: AnaloqItem,
        playbackOffset: TimeInterval
    ) async throws -> StreamResult {
        switch stream.mode {
        case .directPlay, .directStream:
            return try await streamService.streamURL(
                for: item,
                preferTranscode: true,
                playbackOffset: playbackOffset
            )
        case .transcode(let quality):
            if let fallbackQuality = quality.fallbackQuality {
                return try await streamService.streamURL(
                    for: item,
                    preferTranscode: true,
                    preferredQuality: fallbackQuality,
                    playbackOffset: playbackOffset
                )
            }
            return try await streamService.streamURL(
                for: item,
                preferDirect: true,
                playbackOffset: playbackOffset
            )
        }
    }

    private func resetPlaybackProgressTracking() {
        lastObservedPlaybackSecond = nil
        lastPlaybackProgressDate = .now
    }

    private func finitePlaybackSecond(for playerItem: AVPlayerItem) -> Double? {
        let second = CMTimeGetSeconds(playerItem.currentTime())
        return second.isFinite ? second : nil
    }

    private func currentPlaybackSecond() -> Double? {
        guard let currentItem = player.currentItem else { return nil }
        return finitePlaybackSecond(for: currentItem)
    }

    private func isPlaybackAdvancing(since previousSecond: Double?) -> Bool {
        guard player.timeControlStatus == .playing, player.rate > 0.01 else { return false }
        guard let previousSecond, let currentSecond = currentPlaybackSecond() else { return false }
        return currentSecond - previousSecond > 0.18
    }

    private func updatePlaybackProgress(now: Date, playerItem: AVPlayerItem) {
        guard let currentSecond = finitePlaybackSecond(for: playerItem) else { return }
        defer { lastObservedPlaybackSecond = currentSecond }

        guard let lastSecond = lastObservedPlaybackSecond else {
            lastPlaybackProgressDate = now
            return
        }
        if currentSecond - lastSecond > 0.08 {
            lastPlaybackProgressDate = now
        }
    }

    private func isPlaybackLikelyStuck(now: Date, playerItem: AVPlayerItem) -> Bool {
        guard playerItem.status == .readyToPlay else { return false }
        let stalledFor = now.timeIntervalSince(lastPlaybackProgressDate)
        guard stalledFor > 3.2 else { return false }

        let duration = CMTimeGetSeconds(playerItem.duration)
        let current = CMTimeGetSeconds(playerItem.currentTime())
        if duration.isFinite, current.isFinite, duration > 0, duration - current <= 1.0 {
            return false
        }

        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            return true
        }
        if player.rate < 0.01 {
            return true
        }

        // Covers decoder/output freezes where AVPlayer still reports "playing".
        return player.timeControlStatus == .playing && player.rate > 0.01
    }

    private func createReadyPlayerItem(from stream: StreamResult) async throws -> AVPlayerItem {
        let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = stream.mode.isDirectPath ? 1.5 : 2.5
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        player.replaceCurrentItem(with: item)
        let timeout: Duration = stream.mode.isDirectPath ? .seconds(8) : .seconds(14)
        try await waitUntilReady(item, timeout: timeout)
        return item
    }

    private func waitUntilReady(_ item: AVPlayerItem, timeout: Duration) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < timeout {
            switch item.status {
            case .readyToPlay:
                return
            case .failed:
                let message = item.error?.localizedDescription ?? L10n.tr("player.stream_loading_failed")
                throw PlaybackPreparationError.failed(message)
            default:
                try await Task.sleep(for: .milliseconds(120))
            }
        }
        throw PlaybackPreparationError.timeout
    }

    private func setupAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    deinit {
        progressTimer?.invalidate()
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = stalledObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = failedToEndObserver { NotificationCenter.default.removeObserver(obs) }
    }
}

private enum StreamRecoveryPreference {
    case defaultPath
    case preferTranscode(VideoQuality)
}

private enum PlaybackPreparationError: LocalizedError {
    case timeout
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return L10n.tr("player.stream_start_timeout")
        case .failed(let message):
            return message
        }
    }
}
