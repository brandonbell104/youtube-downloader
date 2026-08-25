import Foundation

/// A single downloadable rendition of a video.
///
/// YouTube serves three shapes: *progressive* files that already contain both
/// tracks (capped at 360p/720p), and separate *adaptive* video-only and
/// audio-only files that have to be muxed back together after downloading.
struct StreamOption: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case progressive
        case videoOnly
        case audioOnly
    }

    var id: String
    var url: URL
    var kind: Kind
    /// File extension we should write, derived from the MIME type.
    var container: String
    var mimeType: String?
    var codecs: String?
    var height: Int?
    var width: Int?
    var fps: Int?
    var bitrate: Int?
    var contentLength: Int64?
    var qualityLabel: String?
    var audioSampleRate: Int?

    var hasVideo: Bool { kind != .audioOnly }
    var hasAudio: Bool { kind != .videoOnly }

    /// AVFoundation can only mux MPEG-4 family tracks. WebM/VP9/Opus streams
    /// are still listed, but they can't participate in a merge.
    var isMuxable: Bool {
        container == "mp4" || container == "m4a"
    }

    var isAVPlayable: Bool { isMuxable }

    var displayLabel: String {
        switch kind {
        case .audioOnly:
            let rate = bitrate.map { "\($0 / 1000) kbps" }
            return ["Audio", container.uppercased(), rate].compactMap { $0 }.joined(separator: " · ")
        case .videoOnly, .progressive:
            let resolution = qualityLabel ?? height.map { "\($0)p" } ?? "Video"
            let fpsText = (fps ?? 0) > 30 ? "\(fps!)fps" : nil
            let kindText = kind == .progressive ? "with audio" : nil
            return [resolution, fpsText, container.uppercased(), kindText]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
    }

    var formattedSize: String? { Formatters.bytes(contentLength) }
}
