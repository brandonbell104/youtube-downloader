import Foundation

enum JobState: String, Codable {
    case pending
    case resolving
    case downloading
    case merging
    case completed
    case failed
    case cancelled

    var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }

    var isActive: Bool { !isFinished }

    var displayName: String {
        switch self {
        case .pending: return "Waiting"
        case .resolving: return "Finding streams"
        case .downloading: return "Downloading"
        case .merging: return "Finishing up"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var symbolName: String {
        switch self {
        case .pending: return "clock"
        case .resolving: return "magnifyingglass"
        case .downloading: return "arrow.down.circle"
        case .merging: return "wand.and.stars"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "slash.circle"
        }
    }
}

/// The persistable state of a download.
///
/// Everything the app needs to resume after a relaunch lives here, because
/// background downloads routinely outlive the process that started them.
struct JobRecord: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var sourceURL: String
    var quality: QualityPreference
    var addedAt: Date = Date()
    var state: JobState = .pending
    var metadata: VideoMetadata?
    var plan: DownloadPlan?
    var errorMessage: String?
    var libraryItemID: UUID?

    /// Bytes written so far, keyed by `DownloadSlot.rawValue`.
    var bytesReceived: [String: Int64] = [:]
    /// Bytes expected, keyed by `DownloadSlot.rawValue`. Filled in from the
    /// plan and corrected by the server's `Content-Length` once known.
    var bytesExpected: [String: Int64] = [:]

    var displayTitle: String {
        metadata?.title ?? sourceURL
    }

    var totalReceived: Int64 {
        bytesReceived.values.reduce(0, +)
    }

    var totalExpected: Int64? {
        guard let plan else { return nil }
        let slots = plan.slots.map { $0.slot.rawValue }
        guard !slots.isEmpty else { return nil }
        var total: Int64 = 0
        for slot in slots {
            guard let expected = bytesExpected[slot], expected > 0 else { return nil }
            total += expected
        }
        return total
    }

    var progress: DownloadProgress {
        DownloadProgress(
            downloadedBytes: totalReceived > 0 ? totalReceived : nil,
            totalBytes: totalExpected
        )
    }

    var fractionComplete: Double? {
        switch state {
        case .completed: return 1
        case .merging: return 1
        default: return progress.fraction
        }
    }
}
