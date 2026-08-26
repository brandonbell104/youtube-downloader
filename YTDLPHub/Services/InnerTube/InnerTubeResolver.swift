import Foundation

/// On-device stream extraction.
///
/// Asks YouTube's own playback endpoint — the one the official apps use — for
/// the list of media files behind a video, exactly as the YouTube app does when
/// it starts playback. No third-party service is involved and nothing leaves
/// the device except the request to YouTube itself.
///
/// Different clients get different answers, so several are tried in order,
/// preferring the ones that return media URLs that need no unscrambling.
struct InnerTubeResolver: StreamResolver {
    let name = "On-device extractor"

    var clients: [InnerTubeClient] = InnerTubeClient.orderedDefaults
    var session: URLSession = .shared
    /// Public web key used by youtube.com itself.
    var apiKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"

    func canHandle(_ url: URL) -> Bool {
        YouTubeURL.isYouTube(url) && YouTubeURL.videoID(from: url) != nil
    }

    func resolve(_ url: URL) async throws -> ResolvedMedia {
        guard let videoID = YouTubeURL.videoID(from: url) else {
            throw ResolveError.unsupportedSite(url.host ?? url.absoluteString)
        }

        var lastFailure: Error?

        for client in clients {
            do {
                let response = try await requestPlayer(videoID: videoID, client: client)
                try check(playability: response.playabilityStatus, details: response.videoDetails)

                let streams = await streamOptions(from: response, client: client)
                guard !streams.isEmpty else {
                    lastFailure = ResolveError.noUsableStreams
                    continue
                }

                return ResolvedMedia(
                    metadata: metadata(from: response, videoID: videoID, url: url),
                    streams: streams
                )
            } catch let error as ResolveError {
                switch error {
                // No amount of client-swapping fixes these.
                case .loginRequired, .liveStream, .unavailable:
                    throw error
                default:
                    lastFailure = error
                }
            } catch {
                lastFailure = error
            }
        }

        throw lastFailure ?? ResolveError.noUsableStreams
    }

    // MARK: - Networking

    private func requestPlayer(videoID: String, client: InnerTubeClient) async throws -> InnerTubeResponse {
        guard let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(apiKey)&prettyPrint=false") else {
            throw ResolveError.badResponse("Bad player endpoint.")
        }

        var body: [String: Any] = [
            "context": ["client": client.contextClient],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]

        // Ciphered clients have to tell the server which player build the
        // signature code came from, otherwise the URLs won't verify.
        if client.mayReturnCipheredURLs, let timestamp = await PlayerScript.shared.signatureTimestamp() {
            body["playbackContext"] = [
                "contentPlaybackContext": [
                    "html5Preference": "HTML5_PREF_WANTS",
                    "signatureTimestamp": timestamp,
                ],
            ]
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(client.clientName, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ResolveError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ResolveError.badResponse("YouTube replied with HTTP \(http.statusCode) for the \(client.label) client.")
        }

        do {
            return try JSONDecoder().decode(InnerTubeResponse.self, from: data)
        } catch {
            throw ResolveError.badResponse("YouTube's reply could not be read.")
        }
    }

    // MARK: - Interpretation

    private func check(playability: InnerTubeResponse.PlayabilityStatus?, details: InnerTubeResponse.VideoDetails?) throws {
        if details?.isLive == true {
            throw ResolveError.liveStream
        }

        guard let status = playability?.status?.uppercased() else { return }
        switch status {
        case "OK":
            return
        case "LOGIN_REQUIRED", "AGE_VERIFICATION_REQUIRED", "CONTENT_CHECK_REQUIRED":
            throw ResolveError.loginRequired
        case "LIVE_STREAM_OFFLINE":
            throw ResolveError.liveStream
        default:
            throw ResolveError.unavailable(playability?.message ?? "YouTube won't play this video.")
        }
    }

    private func metadata(from response: InnerTubeResponse, videoID: String, url: URL) -> VideoMetadata {
        let details = response.videoDetails
        return VideoMetadata(
            videoID: details?.videoId ?? videoID,
            title: details?.title ?? "Video \(videoID)",
            channel: details?.author,
            duration: details?.duration,
            thumbnailURL: details?.bestThumbnail ?? YouTubeURL.defaultThumbnail(videoID: videoID),
            sourceURL: YouTubeURL.canonicalWatchURL(videoID: videoID) ?? url,
            isLive: details?.isLive ?? false
        )
    }

    private func streamOptions(from response: InnerTubeResponse, client: InnerTubeClient) async -> [StreamOption] {
        var options: [StreamOption] = []

        for format in response.streamingData?.allFormats ?? [] {
            guard let resolved = await streamURL(for: format) else { continue }
            guard let option = makeOption(format: format, url: resolved) else { continue }
            options.append(option)
        }

        // The same itag can appear under more than one client fallback.
        var seen = Set<String>()
        return options.filter { seen.insert($0.id).inserted }
    }

    private func streamURL(for format: InnerTubeResponse.Format) async -> URL? {
        if let direct = format.url, let url = URL(string: direct) {
            return await PlayerScript.shared.deThrottle(url)
        }
        guard let payload = format.cipherPayload else { return nil }
        return await PlayerScript.shared.resolveCipher(payload)
    }

    private func makeOption(format: InnerTubeResponse.Format, url: URL) -> StreamOption? {
        let (mime, codecs) = format.parsedMime
        guard !mime.isEmpty else { return nil }

        let kind: StreamOption.Kind
        if format.isProgressiveList {
            kind = .progressive
        } else if mime.hasPrefix("audio/") {
            kind = .audioOnly
        } else if mime.hasPrefix("video/") {
            kind = .videoOnly
        } else {
            return nil
        }

        let container: String
        switch mime {
        case "video/mp4": container = "mp4"
        case "audio/mp4": container = "m4a"
        case "video/webm", "audio/webm": container = "webm"
        case "video/3gpp": container = "3gp"
        default: return nil
        }

        return StreamOption(
            id: format.itag.map(String.init) ?? url.absoluteString,
            url: url,
            kind: kind,
            container: container,
            mimeType: mime,
            codecs: codecs,
            height: format.height,
            width: format.width,
            fps: format.fps,
            bitrate: format.bitrate ?? format.averageBitrate,
            contentLength: format.size,
            qualityLabel: format.qualityLabel,
            audioSampleRate: format.sampleRate
        )
    }
}
