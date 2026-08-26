import Foundation

/// A single progress sample emitted by yt-dlp.
struct DownloadProgress: Equatable {
    var downloadedBytes: Int64?
    var totalBytes: Int64?
    var speed: Double?
    var etaSeconds: Int?

    /// 0...1, or `nil` when the total size is not yet known (live streams,
    /// fragmented downloads before the manifest is parsed).
    var fraction: Double? {
        guard let downloadedBytes, let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }

    var percentText: String {
        guard let fraction else { return "—" }
        return String(format: "%.0f%%", fraction * 100)
    }

    /// "12.4 MB of 88.1 MB", or just the downloaded amount if the total is unknown.
    var sizeText: String? {
        let done = Formatters.bytes(downloadedBytes)
        let total = Formatters.bytes(totalBytes)
        switch (done, total) {
        case let (done?, total?): return "\(done) of \(total)"
        case let (done?, nil): return done
        default: return nil
        }
    }

    var speedText: String? { Formatters.speed(speed) }
    var etaText: String? { Formatters.eta(seconds: etaSeconds) }

    /// One line combining whatever we know, for the row subtitle.
    var detailText: String {
        [sizeText, speedText, etaText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
