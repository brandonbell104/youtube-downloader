import AVFoundation
import Foundation
import UIKit

/// Produces poster frames for library items.
///
/// Prefers a frame from the downloaded file so the library still looks right
/// offline, and falls back to YouTube's own thumbnail for audio-only items.
actor ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private var inFlight: [UUID: Task<UIImage?, Never>] = [:]

    func image(for item: LibraryItem) async -> UIImage? {
        if let cached = cachedImage(for: item.id) { return cached }

        if let existing = inFlight[item.id] { return await existing.value }

        let task = Task<UIImage?, Never> { [item] in
            if !item.isAudioOnly, let frame = await Self.frame(from: item.fileURL) {
                return frame
            }
            if let remote = item.remoteThumbnail {
                return await Self.download(remote)
            }
            return nil
        }
        inFlight[item.id] = task

        let image = await task.value
        inFlight[item.id] = nil
        if let image { store(image, for: item.id) }
        return image
    }

    // MARK: - Disk cache

    private func cacheURL(for id: UUID) -> URL {
        Paths.thumbnails.appendingPathComponent("\(id.uuidString).jpg")
    }

    private func cachedImage(for id: UUID) -> UIImage? {
        guard let data = try? Data(contentsOf: cacheURL(for: id)) else { return nil }
        return UIImage(data: data)
    }

    private func store(_ image: UIImage, for id: UUID) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        try? data.write(to: cacheURL(for: id), options: .atomic)
    }

    func forget(_ id: UUID) {
        try? FileManager.default.removeItem(at: cacheURL(for: id))
    }

    // MARK: - Sources

    private static func frame(from fileURL: URL) async -> UIImage? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)

        // A little way in, so we skip fade-ins and black title cards.
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let seconds = duration > 6 ? min(duration * 0.1, 20) : 0
        let time = CMTime(seconds: seconds, preferredTimescale: 600)

        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func download(_ url: URL) async -> UIImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }
}
