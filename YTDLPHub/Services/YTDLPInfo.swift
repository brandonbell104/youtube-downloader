import Foundation

/// yt-dlp's answer about a link, in the shape both yt-dlp-backed resolvers use.
///
/// Deliberately a subset of yt-dlp's own `--dump-json` output, so neither the
/// companion server nor the embedded bridge has to translate anything: they
/// each pick the keys listed here straight out of the info dict.
struct YTDLPInfo: Decodable {
    var id: String?
    var title: String?
    var channel: String?
    var uploader: String?
    var duration: Double?
    var thumbnail: String?
    var webpageURL: String?
    var isLive: Bool?
    var formats: [Format]?
    /// Set when yt-dlp declined the link. The Python and server sides report
    /// failures this way rather than by raising across the boundary.
    var error: String?

    enum CodingKeys: String, CodingKey {
        case id, title, channel, uploader, duration, thumbnail, formats, error
        case webpageURL = "webpage_url"
        case isLive = "is_live"
    }

    static func decode(_ data: Data) throws -> YTDLPInfo {
        do {
            return try JSONDecoder().decode(YTDLPInfo.self, from: data)
        } catch {
            throw ResolveError.badResponse("yt-dlp sent a reply this app couldn't read.")
        }
    }

    /// Turns the payload into the app's own model, or throws the reason it can't.
    func resolvedMedia(requestedURL: URL) throws -> ResolvedMedia {
        if let error, !error.isEmpty {
            throw Self.classify(error)
        }
        if isLive == true {
            throw ResolveError.liveStream
        }

        let streams = formats?.compactMap { $0.streamOption } ?? []
        guard !streams.isEmpty else { throw ResolveError.noUsableStreams }

        let metadata = VideoMetadata(
            videoID: id ?? requestedURL.absoluteString,
            title: title ?? requestedURL.absoluteString,
            channel: channel ?? uploader,
            duration: duration,
            thumbnailURL: thumbnail.flatMap { URL(string: $0) },
            sourceURL: webpageURL.flatMap { URL(string: $0) } ?? requestedURL,
            isLive: isLive ?? false
        )

        return ResolvedMedia(metadata: metadata, streams: streams)
    }

    /// yt-dlp reports everything as prose. Recognising a few of its messages
    /// lets the resolver chain stop early instead of retrying a video that is
    /// never going to become available.
    static func classify(_ message: String) -> ResolveError {
        let lowered = message.lowercased()
        if lowered.contains("sign in") || lowered.contains("age-restricted")
            || lowered.contains("members-only") || lowered.contains("private video") {
            return .loginRequired
        }
        if lowered.contains("live event will begin") || lowered.contains("is live") {
            return .liveStream
        }
        if lowered.contains("unavailable") || lowered.contains("removed")
            || lowered.contains("terminated") || lowered.contains("copyright") {
            return .unavailable(message)
        }
        return .badResponse(message)
    }

    struct Format: Decodable {
        var formatID: String?
        var url: String?
        var ext: String?
        var vcodec: String?
        var acodec: String?
        var height: Int?
        var width: Int?
        var fps: Double?
        var tbr: Double?
        var abr: Double?
        var filesize: Int64?
        var filesizeApprox: Int64?
        var formatNote: String?
        var asr: Int?
        var protocolName: String?

        enum CodingKeys: String, CodingKey {
            case url, ext, vcodec, acodec, height, width, fps, tbr, abr, filesize, asr
            case formatID = "format_id"
            case filesizeApprox = "filesize_approx"
            case formatNote = "format_note"
            case protocolName = "protocol"
        }

        var hasVideo: Bool { let value = vcodec ?? "none"; return value != "none" && !value.isEmpty }
        var hasAudio: Bool { let value = acodec ?? "none"; return value != "none" && !value.isEmpty }

        var streamOption: StreamOption? {
            guard let url, let mediaURL = URL(string: url) else { return nil }
            // Manifest-based formats need a player, not a downloader.
            if let protocolName, protocolName.contains("m3u8") || protocolName.contains("dash") {
                return nil
            }

            let kind: StreamOption.Kind
            switch (hasVideo, hasAudio) {
            case (true, true): kind = .progressive
            case (true, false): kind = .videoOnly
            case (false, true): kind = .audioOnly
            case (false, false): return nil
            }

            var container = ext ?? (kind == .audioOnly ? "m4a" : "mp4")
            if container == "mp4", kind == .audioOnly { container = "m4a" }

            let codecs = [vcodec, acodec]
                .compactMap { $0 }
                .filter { $0 != "none" }
                .joined(separator: ", ")

            return StreamOption(
                id: formatID ?? mediaURL.absoluteString,
                url: mediaURL,
                kind: kind,
                container: container,
                mimeType: nil,
                codecs: codecs.isEmpty ? nil : codecs,
                height: height,
                width: width,
                fps: fps.map { Int($0.rounded()) },
                bitrate: (tbr ?? abr).map { Int($0 * 1000) },
                contentLength: filesize ?? filesizeApprox,
                qualityLabel: formatNote,
                audioSampleRate: asr
            )
        }
    }
}
