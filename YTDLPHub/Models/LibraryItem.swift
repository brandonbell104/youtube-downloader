import Foundation

/// A finished download.
struct LibraryItem: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var title: String
    var videoID: String?
    var sourceURL: String?
    var channel: String?
    /// Path relative to `Paths.library` — see the note there about container
    /// paths changing between installs.
    var relativePath: String
    var remoteThumbnail: URL?
    var duration: Double?
    var fileSize: Int64?
    var addedAt: Date = Date()
    var isAudioOnly: Bool = false
    var qualityLabel: String?

    var fileURL: URL { Paths.libraryURL(for: relativePath) }

    var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    var formattedDuration: String? {
        guard let duration, duration > 0 else { return nil }
        return Formatters.duration(seconds: duration)
    }

    var formattedSize: String? { Formatters.bytes(fileSize) }

    var subtitle: String {
        let parts = [channel, qualityLabel, formattedDuration, formattedSize].compactMap { $0 }
        return parts.joined(separator: " · ")
    }
}
