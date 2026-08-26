import Foundation

/// The slice of YouTube's `/youtubei/v1/player` response we care about.
struct InnerTubeResponse: Decodable {
    var playabilityStatus: PlayabilityStatus?
    var videoDetails: VideoDetails?
    var streamingData: StreamingData?

    struct PlayabilityStatus: Decodable {
        var status: String?
        var reason: String?
        var errorScreen: ErrorScreen?

        /// Reason text lives in a few different places depending on why
        /// playback was refused.
        var message: String? {
            if let reason, !reason.isEmpty { return reason }
            return errorScreen?.playerErrorMessageRenderer?.reason?.text
                ?? errorScreen?.playerErrorMessageRenderer?.subreason?.text
        }
    }

    struct ErrorScreen: Decodable {
        var playerErrorMessageRenderer: PlayerErrorMessageRenderer?
    }

    struct PlayerErrorMessageRenderer: Decodable {
        var reason: SimpleText?
        var subreason: SimpleText?
    }

    struct SimpleText: Decodable {
        var simpleText: String?
        var runs: [Run]?

        var text: String? {
            if let simpleText, !simpleText.isEmpty { return simpleText }
            guard let runs, !runs.isEmpty else { return nil }
            return runs.compactMap { $0.text }.joined()
        }

        struct Run: Decodable {
            var text: String?
        }
    }

    struct VideoDetails: Decodable {
        var videoId: String?
        var title: String?
        var lengthSeconds: String?
        var author: String?
        var channelId: String?
        var isLiveContent: Bool?
        var isLive: Bool?
        var thumbnail: ThumbnailContainer?

        var duration: Double? {
            guard let lengthSeconds, let value = Double(lengthSeconds), value > 0 else { return nil }
            return value
        }

        var bestThumbnail: URL? {
            guard let thumbnails = thumbnail?.thumbnails, !thumbnails.isEmpty else { return nil }
            let best = thumbnails.max { ($0.width ?? 0) < ($1.width ?? 0) }
            return best?.url.flatMap { URL(string: $0) }
        }
    }

    struct ThumbnailContainer: Decodable {
        var thumbnails: [Thumbnail]?
    }

    struct Thumbnail: Decodable {
        var url: String?
        var width: Int?
        var height: Int?
    }

    struct StreamingData: Decodable {
        var expiresInSeconds: String?
        var formats: [Format]?
        var adaptiveFormats: [Format]?
        var hlsManifestUrl: String?

        var allFormats: [Format] {
            (formats ?? []).map { $0.marking(progressive: true) }
                + (adaptiveFormats ?? []).map { $0.marking(progressive: false) }
        }
    }

    struct Format: Decodable {
        var itag: Int?
        var url: String?
        var signatureCipher: String?
        var cipher: String?
        var mimeType: String?
        var bitrate: Int?
        var averageBitrate: Int?
        var width: Int?
        var height: Int?
        var contentLength: String?
        var quality: String?
        var fps: Int?
        var qualityLabel: String?
        var audioQuality: String?
        var audioSampleRate: String?
        var audioChannels: Int?
        var approxDurationMs: String?

        /// Set by `allFormats`; the JSON itself doesn't say which list a format
        /// came from.
        var isProgressiveList: Bool = false

        enum CodingKeys: String, CodingKey {
            case itag, url, signatureCipher, cipher, mimeType, bitrate, averageBitrate
            case width, height, contentLength, quality, fps, qualityLabel
            case audioQuality, audioSampleRate, audioChannels, approxDurationMs
        }

        func marking(progressive: Bool) -> Format {
            var copy = self
            copy.isProgressiveList = progressive
            return copy
        }

        /// The scrambled URL payload, whichever key it arrived under.
        var cipherPayload: String? { signatureCipher ?? cipher }

        var size: Int64? { contentLength.flatMap { Int64($0) } }

        var sampleRate: Int? { audioSampleRate.flatMap { Int($0) } }

        /// `video/mp4; codecs="avc1.640028"` -> ("video/mp4", "avc1.640028")
        var parsedMime: (type: String, codecs: String?) {
            guard let mimeType else { return ("", nil) }
            let parts = mimeType.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            let base = parts.first ?? ""
            let codecs = parts.dropFirst()
                .first(where: { $0.hasPrefix("codecs=") })?
                .replacingOccurrences(of: "codecs=", with: "")
                .replacingOccurrences(of: "\"", with: "")
            return (base, codecs)
        }
    }
}
