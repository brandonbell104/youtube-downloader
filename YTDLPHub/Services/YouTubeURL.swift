import Foundation

/// Parsing helpers for the handful of URL shapes YouTube hands out.
enum YouTubeURL {
    static let hosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com",
        "music.youtube.com", "youtu.be", "www.youtu.be",
        "youtube-nocookie.com", "www.youtube-nocookie.com",
    ]

    /// Accepts a bare ID, a full URL, or a URL missing its scheme.
    static func normalize(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if isPlainVideoID(trimmed) {
            return URL(string: "https://www.youtube.com/watch?v=\(trimmed)")
        }

        var candidate = trimmed
        if !candidate.lowercased().hasPrefix("http://"), !candidate.lowercased().hasPrefix("https://") {
            candidate = "https://" + candidate
        }
        guard let url = URL(string: candidate), url.host != nil else { return nil }
        return url
    }

    static func isYouTube(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }

    static func isPlainVideoID(_ value: String) -> Bool {
        guard value.count == 11 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Extracts the 11-character video ID from any of the supported shapes:
    /// `watch?v=`, `youtu.be/`, `/shorts/`, `/embed/`, `/live/`.
    static func videoID(from url: URL) -> String? {
        if isPlainVideoID(url.absoluteString) { return url.absoluteString }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        if let value = components.queryItems?.first(where: { $0.name == "v" })?.value,
           isPlainVideoID(value) {
            return value
        }

        let host = components.host?.lowercased() ?? ""
        let segments = components.path.split(separator: "/").map(String.init)

        if host.contains("youtu.be"), let first = segments.first, isPlainVideoID(first) {
            return first
        }

        for (index, segment) in segments.enumerated() {
            if ["shorts", "embed", "live", "v"].contains(segment),
               index + 1 < segments.count,
               isPlainVideoID(segments[index + 1]) {
                return segments[index + 1]
            }
        }

        return nil
    }

    /// Playlist ID, when the link points at one.
    static func playlistID(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "list" })?
            .value
    }

    static func canonicalWatchURL(videoID: String) -> URL? {
        URL(string: "https://www.youtube.com/watch?v=\(videoID)")
    }

    static func defaultThumbnail(videoID: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
    }
}
