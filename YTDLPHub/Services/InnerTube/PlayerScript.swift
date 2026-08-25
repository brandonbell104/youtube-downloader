import Foundation
import JavaScriptCore

/// Runs the small pieces of YouTube's player JavaScript that are needed to
/// unscramble media URLs.
///
/// Two transforms live in that file:
///
/// * **signature** — some clients return `signatureCipher=s=…&sp=sig&url=…`
///   instead of a plain URL. The `s` value has to be passed through a shuffle
///   function before being appended to the URL as the `sp` parameter.
/// * **n parameter** — every URL carries an `n=` value. Serving it back
///   untransformed still works, but YouTube throttles the response to a
///   fraction of the real bandwidth, so it is worth transforming.
///
/// Both functions are extracted out of `base.js` by pattern matching and then
/// evaluated in a `JSContext`. This is inherently brittle: YouTube reshapes
/// that file regularly. Every failure path here is non-fatal — the caller
/// falls back to a client whose URLs need no unscrambling, or to a yt-dlp
/// server, which is maintained by people who track these changes daily.
actor PlayerScript {
    static let shared = PlayerScript()

    private struct Compiled {
        var context: JSContext
        var signatureFunction: String?
        var nFunction: String?
        var signatureTimestamp: Int?
    }

    private var cache: [String: Compiled] = [:]
    private var playerIDCache: String?
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public surface

    func signatureTimestamp() async -> Int? {
        guard let compiled = try? await compiled() else { return nil }
        return compiled.signatureTimestamp
    }

    /// Unscrambles a `signatureCipher` payload into a usable URL.
    func resolveCipher(_ payload: String) async -> URL? {
        var query = URLComponents()
        query.percentEncodedQuery = payload
        let items = query.queryItems ?? []

        guard let base = items.first(where: { $0.name == "url" })?.value,
              var components = URLComponents(string: base) else { return nil }

        let scrambled = items.first(where: { $0.name == "s" })?.value
        let parameterName = items.first(where: { $0.name == "sp" })?.value ?? "signature"

        if let scrambled {
            guard let unscrambled = await runSignature(scrambled) else { return nil }
            var queryItems = components.queryItems ?? []
            queryItems.removeAll { $0.name == parameterName }
            queryItems.append(URLQueryItem(name: parameterName, value: unscrambled))
            components.queryItems = queryItems
        }

        guard let url = components.url else { return nil }
        return await deThrottle(url)
    }

    /// Replaces the `n` parameter with its transformed value. Returns the URL
    /// unchanged when the transform is unavailable — a throttled download is
    /// better than no download.
    func deThrottle(_ url: URL) async -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var items = components.queryItems,
              let index = items.firstIndex(where: { $0.name == "n" }),
              let original = items[index].value,
              let transformed = await runNTransform(original),
              transformed != original
        else { return url }

        items[index] = URLQueryItem(name: "n", value: transformed)
        components.queryItems = items
        return components.url ?? url
    }

    // MARK: - Evaluation

    private func runSignature(_ input: String) async -> String? {
        guard let compiled = try? await compiled(), let name = compiled.signatureFunction else { return nil }
        return call(compiled.context, function: name, argument: input)
    }

    private func runNTransform(_ input: String) async -> String? {
        guard let compiled = try? await compiled(), let name = compiled.nFunction else { return nil }
        guard let result = call(compiled.context, function: name, argument: input) else { return nil }
        // A transform that bails out returns a value prefixed with the input,
        // which means the extraction grabbed the wrong function.
        guard !result.hasPrefix("enhanced_except"), !result.isEmpty else { return nil }
        return result
    }

    private nonisolated func call(_ context: JSContext, function: String, argument: String) -> String? {
        guard let callable = context.objectForKeyedSubscript(function),
              !callable.isUndefined else { return nil }
        let result = callable.call(withArguments: [argument])
        guard let result, !result.isUndefined, !result.isNull else { return nil }
        return result.toString()
    }

    // MARK: - Fetching and extraction

    private func compiled() async throws -> Compiled {
        let playerID = try await currentPlayerID()
        if let cached = cache[playerID] { return cached }

        let source = try await fetchPlayerScript(playerID: playerID)
        guard let context = JSContext() else {
            throw ResolveError.badResponse("Could not start a JavaScript context.")
        }
        // Extraction misses are expected and handled by the caller; swallow the
        // JS errors they produce rather than logging noise on every video.
        context.exceptionHandler = { _, _ in }

        var compiled = Compiled(
            context: context,
            signatureFunction: nil,
            nFunction: nil,
            signatureTimestamp: PlayerScriptParser.signatureTimestamp(in: source)
        )

        if let snippet = PlayerScriptParser.signatureFunction(in: source) {
            context.evaluateScript(snippet.source)
            if context.exception == nil {
                compiled.signatureFunction = snippet.entryPoint
            }
            context.exception = nil
        }

        if let snippet = PlayerScriptParser.nTransformFunction(in: source) {
            context.evaluateScript(snippet.source)
            if context.exception == nil {
                compiled.nFunction = snippet.entryPoint
            }
            context.exception = nil
        }

        cache[playerID] = compiled
        return compiled
    }

    /// The player build ID, e.g. `8e7a3f21`. Read from the iframe API, which is
    /// a much smaller download than a watch page.
    private func currentPlayerID() async throws -> String {
        if let playerIDCache { return playerIDCache }

        guard let url = URL(string: "https://www.youtube.com/iframe_api") else {
            throw ResolveError.badResponse("Bad iframe API URL.")
        }
        let (data, _) = try await session.data(from: url)
        guard let body = String(data: data, encoding: .utf8),
              let id = PlayerScriptParser.playerID(in: body) else {
            throw ResolveError.badResponse("Could not determine the current YouTube player version.")
        }
        playerIDCache = id
        return id
    }

    private func fetchPlayerScript(playerID: String) async throws -> String {
        let path = "https://www.youtube.com/s/player/\(playerID)/player_ias.vflset/en_US/base.js"
        guard let url = URL(string: path) else {
            throw ResolveError.badResponse("Bad player script URL.")
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ResolveError.badResponse("Player script request failed (HTTP \(http.statusCode)).")
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw ResolveError.badResponse("Player script was not readable text.")
        }
        return source
    }
}
