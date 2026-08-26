import Foundation

/// One of YouTube's own playback clients.
///
/// The player endpoint returns different data depending on which client asks.
/// The TV and mobile clients hand back plain media URLs; the web client hands
/// back URLs whose signature has to be unscrambled with code from the page's
/// player JavaScript.
///
/// These identifiers are not a published API — they are what the official
/// YouTube apps send, and they change. If extraction starts failing, the
/// version strings here are the first thing to refresh (yt-dlp's
/// `_extractor/youtube/_base.py` tracks the current values).
struct InnerTubeClient: Sendable {
    var label: String
    var clientName: String
    var clientVersion: String
    var clientID: Int
    var userAgent: String
    var deviceMake: String?
    var deviceModel: String?
    var osName: String?
    var osVersion: String?
    /// True when this client's URLs may arrive scrambled.
    var mayReturnCipheredURLs: Bool

    var contextClient: [String: Any] {
        var client: [String: Any] = [
            "clientName": clientName,
            "clientVersion": clientVersion,
            "hl": "en",
            "gl": "US",
            "timeZone": "UTC",
            "utcOffsetMinutes": 0,
        ]
        if let deviceMake { client["deviceMake"] = deviceMake }
        if let deviceModel { client["deviceModel"] = deviceModel }
        if let osName { client["osName"] = osName }
        if let osVersion { client["osVersion"] = osVersion }
        return client
    }

    // MARK: - Known clients, in the order we try them

    /// The iPhone app. Historically the most reliable source of unscrambled,
    /// full-quality URLs.
    static let ios = InnerTubeClient(
        label: "iOS",
        clientName: "IOS",
        clientVersion: "20.10.4",
        clientID: 5,
        userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X; en_US)",
        deviceMake: "Apple",
        deviceModel: "iPhone16,2",
        osName: "iPhone",
        osVersion: "18.3.2.22D82",
        mayReturnCipheredURLs: false
    )

    /// The Quest app. Useful because it is rarely gated behind proof-of-origin
    /// checks.
    static let androidVR = InnerTubeClient(
        label: "Android VR",
        clientName: "ANDROID_VR",
        clientVersion: "1.62.27",
        clientID: 28,
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.62.27 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        deviceMake: "Oculus",
        deviceModel: "Quest 3",
        osName: "Android",
        osVersion: "12L",
        mayReturnCipheredURLs: false
    )

    /// A TV client. Returns ciphered URLs, so it only works when signature
    /// deciphering succeeds.
    static let tvEmbedded = InnerTubeClient(
        label: "TV embedded",
        clientName: "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
        clientVersion: "2.0",
        clientID: 85,
        userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
        deviceMake: nil,
        deviceModel: nil,
        osName: nil,
        osVersion: nil,
        mayReturnCipheredURLs: true
    )

    /// Desktop web. Last resort, always ciphered.
    static let web = InnerTubeClient(
        label: "Web",
        clientName: "WEB",
        clientVersion: "2.20250312.04.00",
        clientID: 1,
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36",
        deviceMake: nil,
        deviceModel: nil,
        osName: nil,
        osVersion: nil,
        mayReturnCipheredURLs: true
    )

    static let orderedDefaults: [InnerTubeClient] = [.ios, .androidVR, .tvEmbedded, .web]
}
