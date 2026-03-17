import Foundation
import AVFoundation

actor StreamService {

    private let serverURL: String
    private let token: String
    private let clientID: String
    #if os(iOS)
    private let platformName = "iOS"
    private let forceTranscodeByDefault = false
    #else
    private let platformName = "tvOS"
    private let forceTranscodeByDefault = true
    #endif

    init(serverURL: String, token: String, clientID: String) {
        self.serverURL = serverURL
        self.token = token
        self.clientID = clientID
    }

    func streamURL(
        for item: AnaloqItem,
        preferTranscode: Bool = false,
        preferDirect: Bool = false,
        preferredQuality: VideoQuality? = nil,
        playbackOffset: TimeInterval = 0
    ) async throws -> StreamResult {
        let headers = serviceHeaders()
        let shouldTranscode = preferTranscode || forceTranscodeByDefault
        if preferDirect {
            return StreamResult(
                url: try universalPlaybackURL(
                    item: item,
                    directPlay: true,
                    videoQuality: .copy,
                    playbackOffset: playbackOffset
                ),
                mode: .directPlay,
                headers: headers
            )
        }
        if shouldTranscode {
            let quality = preferredQuality ?? preferredTranscodeQuality()
            return StreamResult(
                url: try universalPlaybackURL(
                    item: item,
                    directPlay: false,
                    videoQuality: quality,
                    playbackOffset: playbackOffset
                ),
                mode: .transcode(quality: quality),
                headers: headers
            )
        }

        return StreamResult(
            url: try universalPlaybackURL(
                item: item,
                directPlay: true,
                videoQuality: .copy,
                playbackOffset: playbackOffset
            ),
            mode: .directPlay,
            headers: headers
        )
    }

    func stopSession(sessionID: String) async {
        guard let url = URL(string: serverURL + "/video/:/transcode/universal/stop") else { return }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: AnaloqProtocol.tokenHeader)
        _ = try? await URLSession.shared.data(for: request)
    }

    private func universalPlaybackURL(
        item: AnaloqItem,
        directPlay: Bool,
        videoQuality: VideoQuality,
        playbackOffset: TimeInterval
    ) throws -> URL {
        let playbackProfile = playbackProfile(directPlay: directPlay, videoQuality: videoQuality)
        let normalizedOffset = max(playbackOffset, 0)
        var components = URLComponents(string: serverURL + "/video/:/transcode/universal/start.m3u8")!
        components.queryItems = [
            URLQueryItem(name: "session",                   value: UUID().uuidString.lowercased()),
            URLQueryItem(name: AnaloqProtocol.tokenHeader,            value: token),
            URLQueryItem(name: AnaloqProtocol.clientIdentifierHeader, value: clientID),
            URLQueryItem(name: AnaloqProtocol.productHeader,          value: "analoq"),
            URLQueryItem(name: AnaloqProtocol.versionHeader,          value: "1.0"),
            URLQueryItem(name: AnaloqProtocol.deviceHeader,           value: platformName),
            URLQueryItem(name: AnaloqProtocol.platformHeader,         value: platformName),
            URLQueryItem(name: "path",                      value: metadataPath(for: item)),
            URLQueryItem(name: "offset",                    value: String(format: "%.3f", normalizedOffset)),
            URLQueryItem(name: "mediaIndex",                value: "0"),
            URLQueryItem(name: "partIndex",                 value: "0"),
            URLQueryItem(name: "videoQuality",              value: playbackProfile.videoQuality.qualityValue),
            URLQueryItem(name: "videoResolution",           value: playbackProfile.resolution),
            URLQueryItem(name: "maxVideoBitrate",           value: "\(playbackProfile.maxBitrate)"),
            URLQueryItem(name: "directStream",              value: "1"),
            URLQueryItem(name: "directPlay",                value: directPlay ? "1" : "0"),
            URLQueryItem(name: "protocol",                  value: "hls"),
            URLQueryItem(name: "fastSeek",                  value: "1"),
            URLQueryItem(name: "copyts",                    value: "1"),
            URLQueryItem(name: "subtitles",                 value: "burn"),
        ]
        guard let url = components.url else { throw StreamError.transcodeSessionFailed }
        return url
    }

    private func metadataPath(for item: AnaloqItem) -> String {
        if let raw = item.mediaKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw.hasPrefix("/") ? raw : "/\(raw)"
        }
        return "/library/metadata/\(item.id)"
    }

    private func serviceHeaders() -> [String: String] {
        [
            AnaloqProtocol.clientIdentifierHeader: clientID,
            AnaloqProtocol.productHeader: "analoq",
            AnaloqProtocol.versionHeader: "1.0",
            AnaloqProtocol.deviceHeader: platformName,
            AnaloqProtocol.platformHeader: platformName,
            AnaloqProtocol.tokenHeader: token
        ]
    }

    private func preferredTranscodeQuality() -> VideoQuality {
        VideoQuality.defaultTranscodeQuality
    }

    private func playbackProfile(directPlay: Bool, videoQuality: VideoQuality) -> PlaybackProfile {
        if directPlay {
            return PlaybackProfile(
                videoQuality: .copy,
                resolution: DeviceCapabilities.resolutionString,
                maxBitrate: DeviceCapabilities.maxBitrate
            )
        }

        return PlaybackProfile(
            videoQuality: videoQuality,
            resolution: videoQuality.resolution,
            maxBitrate: videoQuality.maxBitrate
        )
    }
}

// MARK: – Supporting Types
struct StreamResult {
    let url: URL
    let mode: StreamMode
    let headers: [String: String]
}

enum StreamMode {
    case directPlay, directStream, transcode(quality: VideoQuality)

    var isDirectPath: Bool {
        switch self {
        case .directPlay, .directStream:
            return true
        case .transcode:
            return false
        }
    }

    var description: String {
        switch self {
        case .directPlay:          return L10n.tr("stream.mode.direct_play")
        case .directStream:        return L10n.tr("stream.mode.direct_stream")
        case .transcode(let q):    return L10n.tr("stream.mode.adaptive", q.label)
        }
    }
}

enum VideoQuality: String {
    case copy = "copy", q4k = "4k", q1080p = "1080", q720p = "720"
    var qualityValue: String { rawValue }
    var label: String {
        switch self {
        case .copy:
            return L10n.tr("video.quality.copy")
        case .q4k:
            return "4K"
        case .q1080p:
            return "1080p"
        case .q720p:
            return "720p"
        }
    }

    static var defaultTranscodeQuality: VideoQuality {
        #if os(tvOS)
        return .q1080p
        #else
        return .q720p
        #endif
    }

    var fallbackQuality: VideoQuality? {
        switch self {
        case .copy:
            return nil
        case .q4k:
            return .q1080p
        case .q1080p:
            return .q720p
        case .q720p:
            return nil
        }
    }

    var resolution: String {
        switch self {
        case .copy:
            return DeviceCapabilities.resolutionString
        case .q4k:
            return "3840x2160"
        case .q1080p:
            return "1920x1080"
        case .q720p:
            return "1280x720"
        }
    }

    var maxBitrate: Int {
        switch self {
        case .copy:
            return DeviceCapabilities.maxBitrate
        case .q4k:
            return 20_000
        case .q1080p:
            return 20_000
        case .q720p:
            return 4_000
        }
    }
}

enum StreamError: LocalizedError {
    case noMediaFound, transcodeSessionFailed
    var errorDescription: String? {
        switch self {
        case .noMediaFound:            return L10n.tr("stream.no_media")
        case .transcodeSessionFailed:  return L10n.tr("stream.transcode_failed")
        }
    }
}

private struct PlaybackProfile {
    let videoQuality: VideoQuality
    let resolution: String
    let maxBitrate: Int
}
