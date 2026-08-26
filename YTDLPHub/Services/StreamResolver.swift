import Foundation

/// The result of turning a link into something downloadable.
struct ResolvedMedia: Equatable {
    var metadata: VideoMetadata
    var streams: [StreamOption]
}

enum ResolveError: LocalizedError, Equatable {
    case notALink(String)
    case unsupportedSite(String)
    case unavailable(String)
    case loginRequired
    case liveStream
    case noUsableStreams
    case network(String)
    case badResponse(String)
    case allResolversFailed([String])

    var errorDescription: String? {
        switch self {
        case .notALink(let value):
            return "\"\(value)\" doesn't look like a link."
        case .unsupportedSite(let host):
            return "\(host) isn't supported. Paste a YouTube link, or point the app at a yt-dlp server in Settings to handle other sites."
        case .unavailable(let reason):
            return reason.isEmpty ? "YouTube says this video isn't available." : reason
        case .loginRequired:
            return "This video needs a signed-in account (age-restricted, private, or members-only)."
        case .liveStream:
            return "This is a live stream. Live broadcasts can't be saved as a file until they end."
        case .noUsableStreams:
            return "No downloadable audio or video streams were offered for this video."
        case .network(let message):
            return message
        case .badResponse(let message):
            return message
        case .allResolversFailed(let messages):
            return messages.first ?? "Couldn't work out how to download this link."
        }
    }
}

/// A strategy for turning a URL into `ResolvedMedia`.
///
/// The app ships two: an on-device extractor that talks to YouTube's own
/// playback API, and a bridge to a yt-dlp server the user runs themselves.
protocol StreamResolver: Sendable {
    var name: String { get }
    /// Whether this resolver is willing to attempt the URL at all.
    func canHandle(_ url: URL) -> Bool
    func resolve(_ url: URL) async throws -> ResolvedMedia
}

/// Tries each resolver in turn and reports the first success.
struct ResolverChain: StreamResolver {
    let name = "Resolver chain"
    var resolvers: [StreamResolver]

    func canHandle(_ url: URL) -> Bool {
        resolvers.contains { $0.canHandle(url) }
    }

    func resolve(_ url: URL) async throws -> ResolvedMedia {
        var failures: [String] = []

        for resolver in resolvers where resolver.canHandle(url) {
            do {
                let media = try await resolver.resolve(url)
                guard !media.streams.isEmpty else {
                    failures.append("\(resolver.name): no streams returned")
                    continue
                }
                return media
            } catch let error as ResolveError {
                // A definitive answer from any resolver ends the chain — trying
                // another one won't make a private video public.
                switch error {
                case .loginRequired, .liveStream, .unavailable:
                    throw error
                default:
                    failures.append("\(resolver.name): \(error.localizedDescription)")
                }
            } catch {
                failures.append("\(resolver.name): \(error.localizedDescription)")
            }
        }

        if failures.isEmpty {
            throw ResolveError.unsupportedSite(url.host ?? url.absoluteString)
        }
        throw ResolveError.allResolversFailed(failures)
    }
}
