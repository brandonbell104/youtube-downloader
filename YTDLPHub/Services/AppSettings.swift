import Foundation

/// User preferences, backed by `UserDefaults`.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    @Published var defaultQuality: QualityPreference {
        didSet { defaults.set(defaultQuality.rawValue, forKey: Key.defaultQuality) }
    }

    /// Ask before downloading, so the user can change quality per video.
    @Published var confirmBeforeDownloading: Bool {
        didSet { defaults.set(confirmBeforeDownloading, forKey: Key.confirmBeforeDownloading) }
    }

    @Published var useRemoteResolver: Bool {
        didSet { defaults.set(useRemoteResolver, forKey: Key.useRemoteResolver) }
    }

    /// Try the yt-dlp server before the on-device extractor. Worth turning on
    /// when a server is always reachable, since yt-dlp keeps up with YouTube's
    /// changes far faster than any bundled extractor can.
    @Published var preferRemoteResolver: Bool {
        didSet { defaults.set(preferRemoteResolver, forKey: Key.preferRemoteResolver) }
    }

    @Published var remoteServerAddress: String {
        didSet { defaults.set(remoteServerAddress, forKey: Key.remoteServerAddress) }
    }

    @Published var remoteServerToken: String {
        didSet { defaults.set(remoteServerToken, forKey: Key.remoteServerToken) }
    }

    @Published var saveToPhotos: Bool {
        didSet { defaults.set(saveToPhotos, forKey: Key.saveToPhotos) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.defaultQuality = defaults.string(forKey: Key.defaultQuality)
            .flatMap(QualityPreference.init(rawValue:)) ?? .fhd1080
        self.confirmBeforeDownloading = defaults.object(forKey: Key.confirmBeforeDownloading) as? Bool ?? true
        self.useRemoteResolver = defaults.bool(forKey: Key.useRemoteResolver)
        self.preferRemoteResolver = defaults.bool(forKey: Key.preferRemoteResolver)
        self.remoteServerAddress = defaults.string(forKey: Key.remoteServerAddress) ?? ""
        self.remoteServerToken = defaults.string(forKey: Key.remoteServerToken) ?? ""
        self.saveToPhotos = defaults.bool(forKey: Key.saveToPhotos)
    }

    var remoteServerURL: URL? {
        let trimmed = remoteServerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        return URL(string: withScheme)
    }

    /// Builds the resolver chain that matches the current settings.
    func makeResolver() -> StreamResolver {
        var resolvers: [StreamResolver] = []
        let onDevice = InnerTubeResolver()

        if useRemoteResolver, let url = remoteServerURL {
            let remote = RemoteResolver(
                baseURL: url,
                token: remoteServerToken.isEmpty ? nil : remoteServerToken
            )
            resolvers = preferRemoteResolver ? [remote, onDevice] : [onDevice, remote]
        } else {
            resolvers = [onDevice]
        }

        return ResolverChain(resolvers: resolvers)
    }

    private enum Key {
        static let defaultQuality = "defaultQuality"
        static let confirmBeforeDownloading = "confirmBeforeDownloading"
        static let useRemoteResolver = "useRemoteResolver"
        static let preferRemoteResolver = "preferRemoteResolver"
        static let remoteServerAddress = "remoteServerAddress"
        static let remoteServerToken = "remoteServerToken"
        static let saveToPhotos = "saveToPhotos"
    }
}
