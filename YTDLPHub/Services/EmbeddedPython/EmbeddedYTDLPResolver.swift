import Foundation

/// Runs the bundled yt-dlp, in this process, on this device.
///
/// The interpreter and yt-dlp's source ship inside the app bundle and are
/// signed with it — nothing is downloaded or executed at runtime that wasn't
/// part of the build. See `YTDLPBridge.h` for why this is possible on iOS when
/// running the yt-dlp *binary* is not.
///
/// This resolver simply isn't available in builds made without running
/// `Scripts/fetch-python.sh`; `canHandle` returns false and the chain moves on.
struct EmbeddedYTDLPResolver: StreamResolver {
    let name = "Bundled yt-dlp"

    /// Whether the runtime and packages made it into this build.
    static var isAvailable: Bool {
        YTDLPBridge.shared.available
    }

    /// Version of the bundled yt-dlp. Boots the interpreter, so call it off the
    /// main thread the first time.
    static var version: String? {
        guard isAvailable else { return nil }
        return YTDLPBridge.shared.ytDlpVersion()
    }

    func canHandle(_ url: URL) -> Bool {
        // yt-dlp supports well over a thousand sites, so anything web-shaped is
        // worth a try.
        Self.isAvailable && url.scheme?.hasPrefix("http") == true
    }

    func resolve(_ url: URL) async throws -> ResolvedMedia {
        guard Self.isAvailable else {
            throw ResolveError.badResponse("This build has no bundled yt-dlp.")
        }

        let json = try await Self.extract(url.absoluteString)

        guard let data = json.data(using: .utf8) else {
            throw ResolveError.badResponse("yt-dlp returned text this app couldn't read.")
        }
        return try YTDLPInfo.decode(data).resolvedMedia(requestedURL: url)
    }

    /// Extraction is a blocking call into CPython that can take several
    /// seconds, so it gets a thread of its own rather than parking one of the
    /// cooperative pool's.
    private static func extract(_ link: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do {
                    let json = try YTDLPBridge.shared.resolveJSON(forURL: link)
                    continuation.resume(returning: json)
                } catch {
                    continuation.resume(throwing: ResolveError.badResponse(error.localizedDescription))
                }
            }
        }
    }
}
