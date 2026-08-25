import Foundation

/// Everything we know about a video before downloading it. Deliberately
/// resolver-agnostic: both the on-device extractor and the remote yt-dlp
/// bridge produce this same shape.
struct VideoMetadata: Codable, Equatable, Identifiable {
    var videoID: String
    var title: String
    var channel: String?
    var duration: Double?
    var thumbnailURL: URL?
    var sourceURL: URL?
    var isLive: Bool = false

    var id: String { videoID }

    var formattedDuration: String? {
        guard let duration, duration > 0 else { return nil }
        return Formatters.duration(seconds: duration)
    }

    static func placeholder(url: URL) -> VideoMetadata {
        VideoMetadata(
            videoID: YouTubeURL.videoID(from: url) ?? url.absoluteString,
            title: url.absoluteString,
            sourceURL: url
        )
    }
}
