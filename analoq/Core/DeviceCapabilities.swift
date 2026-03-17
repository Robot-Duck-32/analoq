import Foundation

struct DeviceCapabilities {

    static let supportedVideoCodecs: Set<String> = [
        "h264", "hevc", "mpeg4", "mjpeg", "vp9"
    ]

    static let supportedAudioCodecs: Set<String> = [
        "aac", "mp3", "ac3", "eac3", "flac", "alac", "dts", "opus", "mp2", "pcm"
    ]

    static let supportedContainers: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "m2ts", "mpegts"
    ]

    #if os(tvOS)
    static let maxVideoResolution = CGSize(width: 3840, height: 2160)
    static let maxBitrate = 80_000
    static let resolutionString = "3840x2160"
    #else
    static let maxVideoResolution = CGSize(width: 1920, height: 1080)
    static let maxBitrate = 20_000
    static let resolutionString = "1920x1080"
    #endif

    static func canDirectPlay(
        videoCodec: String,
        audioCodec: String,
        container: String,
        bitrate: Int? = nil
    ) -> Bool {
        guard supportedVideoCodecs.contains(videoCodec.lowercased()),
              supportedAudioCodecs.contains(audioCodec.lowercased()),
              supportedContainers.contains(container.lowercased())
        else { return false }
        if let bitrate, bitrate > maxBitrate { return false }
        return true
    }
}
