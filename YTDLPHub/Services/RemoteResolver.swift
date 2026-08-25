import Foundation

/// Talks to a yt-dlp instance the user runs themselves.
///
/// iOS can't execute yt-dlp — apps may not spawn subprocesses or run
/// downloaded code — so when the on-device extractor can't handle a link (a
/// non-YouTube site, or a video behind a check it doesn't implement), the app
/// can ask a machine that *can* run yt-dlp to do the extraction and hand back
/// direct media URLs. The download itself still happens on the device.
///
/// `Server/ytdlp_hub_server.py` in this repository is a reference
/// implementation of the endpoint.
struct RemoteResolver: StreamResolver {
    let name = "yt-dlp server"

    var baseURL: URL
    var token: String?
    var session: URLSession = .shared

    func canHandle(_ url: URL) -> Bool {
        url.scheme?.hasPrefix("http") == true
    }

    func resolve(_ url: URL) async throws -> ResolvedMedia {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("resolve"), resolvingAgainstBaseURL: false) else {
            throw ResolveError.badResponse("The yt-dlp server address in Settings isn't a valid URL.")
        }
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        guard let endpoint = components.url else {
            throw ResolveError.badResponse("The yt-dlp server address in Settings isn't a valid URL.")
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 60
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ResolveError.network("Couldn't reach the yt-dlp server: \(error.localizedDescription)")
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let detail = (try? JSONDecoder().decode(RemoteError.self, from: data))?.error
            throw ResolveError.badResponse(detail ?? "The yt-dlp server replied with HTTP \(http.statusCode).")
        }

        let payload: RemoteInfo
        do {
            payload = try JSONDecoder().decode(RemoteInfo.self, from: data)
        } catch {
            throw ResolveError.badResponse("The yt-dlp server sent a reply this app couldn't read.")
        }

        if payload.isLive == true { throw ResolveError.liveStream }

        let streams = payload.formats?.compactMap { $0.streamOption } ?? []
        guard !streams.isEmpty else { throw ResolveError.noUsableStreams }

        let metadata = VideoMetadata(
            videoID: payload.id ?? url.absoluteString,
            title: payload.title ?? url.absoluteString,
            channel: payload.channel ?? payload.uploader,
            duration: payload.duration,
            thumbnailURL: payload.thumbnail.flatMap { URL(string: $0) },
            sourceURL: payload.webpageURL.flatMap { URL(string: $0) } ?? url,
            isLive: payload.isLive ?? false
        )

        return ResolvedMedia(metadata: metadata, streams: streams)
    }

    // MARK: - Wire format
    //
    // Deliberately a subset of yt-dlp's own `--dump-json` output so the server
    // can forward what yt-dlp produces with almost no translation.

    private struct RemoteError: Decodable {
        var error: String?
    }

    private struct RemoteInfo: Decodable {
        var id: String?
        var title: String?
        var channel: String?
        var uploader: String?
        var duration: Double?
        var thumbnail: String?
        var webpageURL: String?
        var isLive: Bool?
        var formats: [RemoteFormat]?

        enum CodingKeys: String, CodingKey {
            case id, title, channel, uploader, duration, thumbnail, formats
            case webpageURL = "webpage_url"
            case isLive = "is_live"
        }
    }

    private struct RemoteFormat: Decodable {
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
            if let protocolName, protocolName.contains("m3u8") || protocolName.contains("dash") { return nil }

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
