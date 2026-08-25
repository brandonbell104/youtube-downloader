import Foundation

/// Observable wrapper around a `JobRecord`.
///
/// Rows observe an individual job so a fast-moving progress update only
/// re-renders that one row rather than the whole list.
@MainActor
final class DownloadJob: ObservableObject, Identifiable {
    @Published var record: JobRecord

    nonisolated var id: UUID { _id }
    private let _id: UUID

    init(record: JobRecord) {
        self.record = record
        self._id = record.id
    }

    convenience init(sourceURL: String, quality: QualityPreference) {
        self.init(record: JobRecord(sourceURL: sourceURL, quality: quality))
    }

    var state: JobState { record.state }
    var title: String { record.displayTitle }

    var statusText: String {
        switch record.state {
        case .downloading:
            let detail = record.progress.detailText
            return detail.isEmpty ? "Downloading…" : detail
        case .failed:
            return record.errorMessage ?? "Something went wrong."
        case .completed:
            return [record.metadata?.formattedDuration, Formatters.bytes(record.totalReceived)]
                .compactMap { $0 }
                .joined(separator: " · ")
        default:
            return record.state.displayName
        }
    }
}
