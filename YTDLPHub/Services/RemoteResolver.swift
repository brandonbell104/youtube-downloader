import Foundation

/// Talks to a yt-dlp instance the user runs themselves.
///
/// Useful when you'd rather update yt-dlp with `pip install -U` than rebuild
/// the app, or when the bundled copy wasn't included in the build. The download
/// itself still happens on the device; the server only does extraction.
///
/// `Server/ytdlp_hub_server.py` in this repository is a reference
/// implementation of the endpoint. It answers with the same payload shape the
/// bundled bridge produces, so both decode through `YTDLPInfo`.
struct RemoteResolver: StreamResolver {
    let name = "yt-dlp server"

    var baseURL: URL
    var token: String?
    var session: URLSession = .shared

    func canHandle(_ url: URL) -> Bool {
        url.scheme?.hasPrefix("http") == true
    }

    func resolve(_ url: URL) async throws -> ResolvedMedia {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("resolve"),
            resolvingAgainstBaseURL: false
        ) else {
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
            // The server reports refusals through the same `error` key, so read
            // the reason rather than losing it behind a status code.
            if let info = try? YTDLPInfo.decode(data), let message = info.error, !message.isEmpty {
                throw YTDLPInfo.classify(message)
            }
            throw ResolveError.badResponse("The yt-dlp server replied with HTTP \(http.statusCode).")
        }

        return try YTDLPInfo.decode(data).resolvedMedia(requestedURL: url)
    }
}
